use anyhow::{Context, Result};
use command_run::{Command, LogTo};
use serde::Deserialize;
use sha2::Digest;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Component, Path, PathBuf};

use crate::Source;
use crate::data::Nixpkgs;
use crate::data::import::{DesktopEntry, NixOption, NixpkgsEntry, Package};

/// Wrapper for the channel `packages.json` format.
#[derive(Deserialize)]
struct PackagesInfo {
    packages: HashMap<String, Package>,
}

/// The output of `flake-info/scripts/desktop-entries-index.py`, which reads
/// desktop entries out of the binary cache. `packages.json` is produced by
/// evaluation alone, so it only sees entries nixpkgs itself constructs and never
/// sees an icon file, which exists only once the package is built.
#[derive(Deserialize)]
struct DesktopIndex {
    packages: HashMap<String, DesktopIndexPackage>,
}

#[derive(Deserialize, Default)]
struct DesktopIndexPackage {
    #[serde(rename = "desktopEntries", default)]
    desktop_entries: Vec<DesktopEntry>,
    /// Which file in the scanner's `--icon-dir` serves each icon name the
    /// entries refer to. The images are files beside the index rather than
    /// bytes inside it, so that directory has to be passed here too --
    /// `--icon-dir` -- for them to be found.
    #[serde(default)]
    icons: HashMap<String, String>,
}

/// The file the scanner wrote for one icon, if `file` is a name it could have
/// written. A name arrives in a file this importer was pointed at and is then
/// used as a path, so it is checked to be a bare file name rather than trusted
/// to stay inside the directory.
fn icon_source(dir: &Path, file: &str) -> Option<PathBuf> {
    let mut components = Path::new(file).components();
    match (components.next(), components.next()) {
        (Some(Component::Normal(name)), None) => Some(dir.join(name)),
        _ => None,
    }
}

/// Where an icon theme keeps application icons, most detailed first. Scalable
/// icons scale to whatever size the frontend asks for; the raster sizes are a
/// fallback for themes that ship no scalable variant.
const ICON_THEME_DIRS: [&str; 4] = ["scalable/apps", "128x128/apps", "64x64/apps", "48x48/apps"];

/// The image formats that can be indexed, as the file extension they carry.
/// Every browser renders both, which the other formats a `.desktop` file may
/// name -- XPM above all -- do not.
const ICON_EXTENSIONS: [&str; 2] = ["svg", "png"];

/// Fills in icons for entries that arrived without one, from a freedesktop icon
/// theme directory such as `${papirus-icon-theme}/share/icons/Papirus`.
/// Evaluation knows an entry's icon *name* but never its file, so entries that
/// did not come through the binary-cache scanner have nothing to render without
/// a theme to look them up in.
struct IconTheme {
    root: PathBuf,
    /// Icon names repeat heavily across packages, and a miss is as worth
    /// remembering as a hit: it is up to eight failed lookups.
    seen: HashMap<String, Option<PathBuf>>,
}

impl IconTheme {
    fn new(root: PathBuf) -> Self {
        IconTheme {
            root,
            seen: HashMap::new(),
        }
    }

    fn lookup(&mut self, icon: &str) -> Option<PathBuf> {
        // An icon given as an absolute path names a store path that this
        // process has no reason to have, and is not a theme name either.
        if icon.contains('/') || icon.is_empty() {
            return None;
        }
        if let Some(cached) = self.seen.get(icon) {
            return cached.clone();
        }
        let found = ICON_THEME_DIRS
            .iter()
            .flat_map(|dir| {
                ICON_EXTENSIONS
                    .iter()
                    .map(move |extension| (dir, extension))
            })
            .map(|(dir, extension)| self.root.join(dir).join(format!("{icon}.{extension}")))
            .find(|path| path.is_file());
        self.seen.insert(icon.to_owned(), found.clone());
        found
    }

    /// Adds an icon per entry that names one the package itself did not supply.
    fn fill(&mut self, entries: &[DesktopEntry], icons: &mut HashMap<String, PathBuf>) {
        for entry in entries {
            let Some(icon) = entry.icon.as_deref() else {
                continue;
            };
            if icons.contains_key(icon) {
                continue;
            }
            if let Some(path) = self.lookup(icon) {
                icons.insert(icon.to_owned(), path);
            }
        }
    }
}

/// Interns icon images under content-addressed file names, so that a package
/// document carries a name an `<img>` can point at rather than the image
/// itself. Each distinct image is emitted once, as its own document, from
/// which the frontend build writes a static file.
#[derive(Default)]
struct IconStore {
    files: HashMap<String, String>,
    /// What each source file was interned as, so that one file is read and
    /// hashed once however many packages point at it -- an icon theme supplies
    /// one file to every package that names it -- and a source that cannot be
    /// served is reported once rather than once per package.
    seen: HashMap<PathBuf, Option<String>>,
}

impl IconStore {
    /// Turns a package's `icon name -> source file` map into `icon name ->
    /// served file name`, keeping the image behind.
    ///
    /// An image in a format that is not in `ICON_EXTENSIONS` is dropped rather
    /// than served under a name no browser can read. XPM is the case in
    /// practice: a valid freedesktop icon format that no browser renders, and
    /// one the scanner will hand over unless told otherwise. A dropped icon
    /// leaves a card looking exactly like one whose package ships none.
    fn intern(&mut self, sources: HashMap<String, PathBuf>) -> HashMap<String, String> {
        sources
            .into_iter()
            .filter_map(|(name, source)| Some((name, self.file_for(source)?)))
            .collect()
    }

    fn file_for(&mut self, source: PathBuf) -> Option<String> {
        if let Some(cached) = self.seen.get(&source) {
            return cached.clone();
        }
        let read = Self::read(&source);
        let file = read.as_ref().map(|(file, _)| file.clone());
        if let Some((file, data)) = read {
            self.files.entry(file).or_insert(data);
        }
        self.seen.insert(source, file.clone());
        file
    }

    /// -> `(file name, base64 image)`, or None if the file cannot be served.
    ///
    /// The name follows the image, so that one image is one file however many
    /// packages point at it and however often an import runs. A name that only
    /// ever changes with its contents is also a name a browser can cache
    /// forever. 128 bits is far past any collision risk at this scale and
    /// keeps the name short enough to read.
    fn read(source: &Path) -> Option<(String, String)> {
        let extension = source.extension()?.to_str()?;
        if !ICON_EXTENSIONS.contains(&extension) {
            return None;
        }
        let bytes = match std::fs::read(source) {
            Ok(bytes) => bytes,
            Err(error) => {
                log::warn!("Could not read icon {}: {}", source.display(), error);
                return None;
            }
        };
        let mut sha = sha2::Sha256::new();
        sha.update(&bytes);
        let file = format!("{:x}", sha.finalize())[..32].to_owned() + "." + extension;
        Some((file, base64::encode(&bytes)))
    }
}

/// Pools the desktop entries' translations across every package, one map per
/// locale, from which the frontend build writes one static file each.
///
/// Keyed by the string translated rather than by the package that carried it.
/// One English string is then translated once however many packages use it, and
/// a locale file written by an earlier deploy still translates every string it
/// knows once a later import has added packages -- where keying by package or by
/// position in a package's entry list would go stale the moment either changed.
#[derive(Default)]
struct LocalizationStore {
    locales: HashMap<String, BTreeMap<String, String>>,
}

impl LocalizationStore {
    fn collect(&mut self, entries: &[DesktopEntry]) {
        for entry in entries {
            for (locale, localized) in &entry.localized {
                let strings = self.locales.entry(locale.clone()).or_default();
                for (source, translation) in [
                    (&entry.desktop_name, &localized.desktop_name),
                    (&entry.generic_name, &localized.generic_name),
                    (&entry.comment, &localized.comment),
                ] {
                    // An entry with no unlocalized string to translate from
                    // cannot be looked up, and one whose translation is the
                    // original -- a proper noun, most often -- costs bytes to
                    // say nothing.
                    let (Some(source), Some(translation)) = (source, translation) else {
                        continue;
                    };
                    if source != translation {
                        strings.insert(source.clone(), translation.clone());
                    }
                }
            }
        }
    }
}

pub fn get_nixpkgs_info(
    nixpkgs: &Source,
    attribute: &Option<String>,
    packages_json_url: &Option<String>,
    repology_counts_file: &Option<PathBuf>,
    user_agent: &Option<String>,
    desktop_entries_file: &Option<PathBuf>,
    icon_dir: &Option<PathBuf>,
    icon_theme_dir: &Option<PathBuf>,
) -> Result<Vec<NixpkgsEntry>> {
    let nixpkgs = match nixpkgs {
        Source::Nixpkgs(nixpkgs) => nixpkgs,
        other => anyhow::bail!(
            "package import requires a nixpkgs channel, got {}",
            other.to_flake_ref(),
        ),
    };

    let url = packages_json_url.clone().unwrap_or_else(|| {
        format!(
            "https://channels.nixos.org/nixos-{}/packages.json.br",
            nixpkgs.channel,
        )
    });
    log::info!("Fetching packages from {}", url);

    let response = reqwest::blocking::Client::builder()
        .user_agent(crate::user_agent::resolve(user_agent.as_deref()))
        .build()?
        .get(&url)
        .send()
        .with_context(|| format!("Failed to download {}", url))?
        .error_for_status()
        .with_context(|| format!("HTTP error fetching {}", url))?;
    let body = response.bytes()?;
    let info: PackagesInfo =
        serde_json::from_slice(&body).with_context(|| "Could not parse channel packages.json")?;

    let attr_set: HashMap<String, Package> = match attribute {
        Some(prefix) => info
            .packages
            .into_iter()
            .filter(|(key, _)| key.starts_with(prefix.as_str()))
            .collect(),
        None => info.packages,
    };

    let mut programs = get_nixpkgs_programs(nixpkgs)?;
    let mut package_services =
        get_nixpkgs_package_services(&Source::Nixpkgs(nixpkgs.clone())).unwrap_or_default();
    // Skip the slow eval when only importing a single attribute.
    let dep_counts = if attribute.is_none() {
        super::get_nixpkgs_dep_counts(nixpkgs)?
    } else {
        HashMap::new()
    };
    let repology_counts = if attribute.is_some() {
        HashMap::new()
    } else {
        resolve_repology_counts(repology_counts_file, user_agent.as_deref())
    };
    let mut desktop_index = resolve_desktop_entries(desktop_entries_file);
    let mut icon_theme = icon_theme_dir.clone().map(IconTheme::new);
    let mut icon_store = IconStore::default();
    let mut localization = LocalizationStore::default();

    let mut entries: Vec<NixpkgsEntry> = attr_set
        .into_iter()
        .map(|(attribute, mut package)| {
            // Where each of this package's icons is to be read from: a file the
            // scanner wrote, or failing that one the icon theme supplies.
            let mut icon_sources: HashMap<String, PathBuf> = HashMap::new();
            if let Some(indexed) = desktop_index.remove(&attribute) {
                // The scanner reads the entries a package actually ships, so it
                // also covers the ones nixpkgs takes verbatim from upstream and
                // evaluation therefore cannot see. Where it found nothing, keep
                // whatever evaluation did see.
                if !indexed.desktop_entries.is_empty() {
                    package.desktop_entries = indexed.desktop_entries;
                }
                if let Some(dir) = icon_dir {
                    icon_sources = indexed
                        .icons
                        .into_iter()
                        .filter_map(|(name, file)| Some((name, icon_source(dir, &file)?)))
                        .collect();
                }
            }
            if let Some(theme) = icon_theme.as_mut() {
                theme.fill(&package.desktop_entries, &mut icon_sources);
            }
            package.icons = icon_store.intern(icon_sources);
            localization.collect(&package.desktop_entries);
            let programs = programs
                .remove(&attribute)
                .unwrap_or_default()
                .into_iter()
                .collect();
            let modular_services = package_services.remove(&attribute).unwrap_or_default();
            let dep_count = dep_counts.get(&attribute).copied();
            let repology_repos = repology_counts.get(&attribute).copied();
            NixpkgsEntry::Derivation {
                attribute,
                package,
                programs,
                modular_services,
                dep_count,
                repology_repos,
            }
        })
        .collect();

    // One document per distinct image, from which the frontend build writes a
    // static file. Kept out of the package documents so that a search response
    // carries names rather than images.
    entries.extend(
        icon_store
            .files
            .into_iter()
            .map(|(file, data)| NixpkgsEntry::Icon { file, data }),
    );

    // One document per locale, likewise: a search response carries the entries
    // in the language they were written in, and a visitor who wants another
    // fetches that one language once for the whole corpus.
    entries.extend(
        localization
            .locales
            .into_iter()
            .map(|(locale, strings)| NixpkgsEntry::Localization { locale, strings }),
    );

    Ok(entries)
}

/// Repology counts for a full import: from a pre-fetched file when provided
/// (missing/unreadable -> warn + empty, per the daily-cache design), otherwise
/// a live best-effort crawl (local/dev/manual and archive/group paths).
fn resolve_repology_counts(
    file: &Option<PathBuf>,
    user_agent: Option<&str>,
) -> HashMap<String, u64> {
    match file {
        Some(path) => match super::load_repology_repo_counts(path) {
            Ok(counts) => {
                log::info!(
                    "Loaded {} Repology counts from {}",
                    counts.len(),
                    path.display()
                );
                counts
            }
            Err(err) => {
                log::warn!(
                    "Skipping Repology counts from {}: {:#}",
                    path.display(),
                    err
                );
                HashMap::new()
            }
        },
        None => super::get_repology_repo_counts(user_agent).unwrap_or_else(|err| {
            log::warn!("Skipping Repology repository counts: {:#}", err);
            HashMap::new()
        }),
    }
}

/// Desktop entries from a scanner run, or nothing when no file was given. An
/// unreadable file drops the signal rather than failing the import, matching how
/// the Repology counts are treated: entries are decoration on a package, not a
/// reason to have no package.
fn resolve_desktop_entries(file: &Option<PathBuf>) -> HashMap<String, DesktopIndexPackage> {
    let Some(path) = file else {
        return HashMap::new();
    };
    match load_desktop_entries(path) {
        Ok(packages) => {
            log::info!(
                "Loaded desktop entries for {} packages from {}",
                packages.len(),
                path.display()
            );
            packages
        }
        Err(err) => {
            log::warn!(
                "Skipping desktop entries from {}: {:#}",
                path.display(),
                err
            );
            HashMap::new()
        }
    }
}

fn load_desktop_entries(path: &PathBuf) -> Result<HashMap<String, DesktopIndexPackage>> {
    let bytes = std::fs::read(path)
        .with_context(|| format!("Failed to read desktop entries file {}", path.display()))?;
    let index: DesktopIndex = serde_json::from_slice(&bytes)
        .with_context(|| format!("Failed to parse desktop entries file {}", path.display()))?;
    Ok(merge_desktop_index(index))
}

fn merge_desktop_index(index: DesktopIndex) -> HashMap<String, DesktopIndexPackage> {
    let mut packages: HashMap<String, DesktopIndexPackage> = HashMap::new();
    for (attribute, package) in index.packages {
        // One index covers every system, so several of its keys can normalise to
        // the same attribute. Keep whichever of them found entries.
        let merged = packages
            .entry(strip_system(&attribute).to_owned())
            .or_default();
        if merged.desktop_entries.is_empty() {
            *merged = package;
        }
    }
    packages
}

/// The scanner keys by attribute path and system, as `nix-env --out-path` prints
/// them (`vlc.x86_64-linux`); `packages.json` covers one system and keys by
/// attribute path alone. Attribute paths contain dots of their own, so only a
/// trailing component that looks like a system is dropped.
fn strip_system(attribute: &str) -> &str {
    match attribute.rsplit_once('.') {
        Some((prefix, system)) if is_system(system) => prefix,
        _ => attribute,
    }
}

fn is_system(component: &str) -> bool {
    matches!(
        component.rsplit_once('-'),
        Some((arch, os)) if !arch.is_empty() && matches!(os, "linux" | "darwin")
    )
}

pub fn get_nixpkgs_package_services(nixpkgs: &Source) -> Result<HashMap<String, Vec<String>>> {
    let mut command = super::nix_eval_command(&["eval", "--json", "--no-write-lock-file"]);
    super::add_flake_arg(&mut command, "nixpkgsFlake", &nixpkgs.to_flake_ref());
    command.add_arg("nixos-package-services");

    let cow = super::run_capturing_stderr(&mut command)
        .with_context(|| "Failed to gather modular service mapping for packages")?;

    let output = &*cow.stdout_string_lossy();
    let de = &mut serde_json::Deserializer::from_str(output);
    let map: HashMap<String, Vec<String>> = serde_path_to_error::deserialize(de)
        .with_context(|| "Could not parse package-services map")?;
    Ok(map)
}

pub fn get_nixpkgs_programs(nixpkgs: &Nixpkgs) -> Result<HashMap<String, HashSet<String>>> {
    let mut command = Command::with_args(
        "nix",
        &["eval", "--raw", "--impure", "--no-write-lock-file"],
    );
    command.add_args(&[
        "-I",
        format!("nixpkgs=channel:nixos-{}", nixpkgs.channel).as_str(),
        "--expr",
        "toString <nixpkgs/programs.sqlite>",
    ]);
    command.enable_capture();
    command.log_to = LogTo::Log;
    command.log_output_on_error = true;

    let cow = super::run_capturing_stderr(&mut command)
        .with_context(|| "Failed to gather information about nixpkgs programs")?;

    let output = cow.stdout_string_lossy();
    let programs_db = output.trim();
    let conn = sqlite::open(programs_db)?;
    let cur = conn
        .prepare("SELECT name, package FROM Programs")?
        .into_iter();

    let mut programs: HashMap<String, HashSet<String>> = HashMap::new();
    for row in cur.map(|r| r.unwrap()) {
        let name: &str = row.read("name");
        let package: &str = row.read("package");
        programs
            .entry(package.into())
            .or_default()
            .insert(name.into());
    }

    Ok(programs)
}

fn get_options_from_script(
    nixpkgs: &Source,
    attribute: &str,
    target_flake: Option<&str>,
) -> Result<Vec<NixOption>> {
    let mut command = super::nix_eval_command(&["eval", "--json", "--no-write-lock-file"]);
    super::add_flake_arg(&mut command, "nixpkgsFlake", &nixpkgs.to_flake_ref());
    if let Some(flake_ref) = target_flake {
        super::add_flake_arg(&mut command, "targetFlake", flake_ref);
    }
    command.add_arg(attribute);

    let cow = super::run_capturing_stderr(&mut command)
        .with_context(|| format!("Failed to gather information about {}", attribute))?;

    let output = &*cow.stdout_string_lossy();
    let de = &mut serde_json::Deserializer::from_str(output);
    let attr_set: Vec<NixOption> = serde_path_to_error::deserialize(de)
        .with_context(|| format!("Could not parse {}", attribute))?;

    Ok(attr_set)
}

pub fn get_nixpkgs_options(nixpkgs: &Source) -> Result<Vec<NixpkgsEntry>> {
    let options = get_options_from_script(nixpkgs, "nixos-options", None)?;
    Ok(options.into_iter().map(NixpkgsEntry::Option).collect())
}

pub fn get_nixpkgs_services(nixpkgs: &Source) -> Result<Vec<NixpkgsEntry>> {
    let options = get_options_from_script(nixpkgs, "nixos-services", None)?;
    Ok(options.into_iter().map(NixpkgsEntry::Service).collect())
}

fn flake_ref_for(nixpkgs: &Source, base: &str, suffix_pattern: Option<&str>) -> String {
    match nixpkgs {
        Source::Nixpkgs(Nixpkgs { channel, .. }) if channel != "unstable" => {
            let suffix = match suffix_pattern {
                Some(pat) => pat.replace("{channel}", channel),
                None => format!("release-{channel}"),
            };
            format!("{base}/{suffix}")
        }
        _ => base.to_string(),
    }
}

/// Home-manager flake reference matching a given nixpkgs channel. Stable
/// nixpkgs channels (`nixos-XX.YY`) get the corresponding `release-XX.YY`
/// branch in `nix-community/home-manager`; `nixos-unstable` gets `master`.
fn home_manager_flake_ref(nixpkgs: &Source) -> String {
    flake_ref_for(nixpkgs, "github:nix-community/home-manager", None)
}

pub fn get_home_manager_options(nixpkgs: &Source) -> Result<Vec<NixpkgsEntry>> {
    let hm_flake_ref = home_manager_flake_ref(nixpkgs);
    let options = get_options_from_script(nixpkgs, "home-manager-options", Some(&hm_flake_ref))?;
    Ok(options
        .into_iter()
        .map(NixpkgsEntry::HomeManagerOption)
        .collect())
}

/// Nix-darwin flake reference matching a given nixpkgs channel. Stable
/// nixpkgs channels (`nixos-XX.YY`) get the corresponding `nix-darwin-XX.YY`
/// branch in `nix-darwin/nix-darwin`; `nixos-unstable` gets `master`.
fn darwin_flake_ref(nixpkgs: &Source) -> String {
    flake_ref_for(
        nixpkgs,
        "github:nix-darwin/nix-darwin",
        Some("nix-darwin-{channel}"),
    )
}

pub fn get_darwin_options(nixpkgs: &Source) -> Result<Vec<NixpkgsEntry>> {
    let darwin_flake_ref = darwin_flake_ref(nixpkgs);
    let options = get_options_from_script(nixpkgs, "darwin-options", Some(&darwin_flake_ref))?;
    Ok(options
        .into_iter()
        .map(NixpkgsEntry::DarwinOption)
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::data::import::LocalizedEntry;

    #[test]
    fn test_packages_info_deserialize() {
        // Regression test for https://github.com/NixOS/nixos-search/issues/770:
        // `pname` and `version` must come straight from the channel's
        // `packages.json`, not be re-derived by splitting `name`. These
        // attribute names historically tripped up the `nix-env` heuristic.
        let json = r#"
        {
            "version": "2",
            "packages": {
                "librecast": {
                    "name": "librecast-X",
                    "pname": "librecast",
                    "version": "X",
                    "system": "x86_64-linux",
                    "outputName": "out",
                    "outputs": { "out": null },
                    "meta": {}
                },
                "SP800-90B_EntropyAssessment": {
                    "name": "SP800-90B_EntropyAssessment-Y",
                    "pname": "SP800-90B_EntropyAssessment",
                    "version": "Y",
                    "system": "x86_64-linux",
                    "outputName": "out",
                    "outputs": { "out": null },
                    "meta": {}
                }
            }
        }
        "#;

        let info: PackagesInfo = serde_json::from_str(json).unwrap();

        assert_eq!(info.packages.len(), 2);
        assert_eq!(info.packages["librecast"].pname, "librecast");
        assert_eq!(
            info.packages["SP800-90B_EntropyAssessment"].pname,
            "SP800-90B_EntropyAssessment",
        );
    }

    #[test]
    fn test_packages_info_desktop_entries() {
        // Desktop entries are additive: index versions before 52 have no
        // `desktopEntries` key at all, and most packages never will.
        let json = r#"
        {
            "version": "2",
            "packages": {
                "abaddon": {
                    "name": "abaddon-0.2.2",
                    "pname": "abaddon",
                    "version": "0.2.2",
                    "system": "x86_64-linux",
                    "outputName": "out",
                    "outputs": { "out": null },
                    "meta": {},
                    "desktopEntries": [
                        {
                            "type": "Application",
                            "desktopName": "Abaddon",
                            "icon": "abaddon",
                            "mimeTypes": ["x-scheme-handler/discord"],
                            "categories": ["Network", "InstantMessaging"]
                        }
                    ]
                },
                "krita": {
                    "name": "krita-6.0.2.1",
                    "pname": "krita",
                    "version": "6.0.2.1",
                    "system": "x86_64-linux",
                    "outputName": "out",
                    "outputs": { "out": null },
                    "meta": {},
                    "desktopEntries": [
                        {
                            "type": "Application",
                            "desktopName": "Krita",
                            "icon": "krita",
                            "mimeTypes": [],
                            "categories": ["Graphics"]
                        },
                        {
                            "type": "Application",
                            "desktopName": "Krita",
                            "icon": "krita",
                            "mimeTypes": ["application/pdf"],
                            "categories": ["Graphics"],
                            "noDisplay": true
                        }
                    ]
                },
                "hello": {
                    "name": "hello-2.12.2",
                    "pname": "hello",
                    "version": "2.12.2",
                    "system": "x86_64-linux",
                    "outputName": "out",
                    "outputs": { "out": null },
                    "meta": {}
                }
            }
        }
        "#;

        let info: PackagesInfo = serde_json::from_str(json).unwrap();

        let abaddon = &info.packages["abaddon"].desktop_entries;
        assert_eq!(abaddon.len(), 1);
        assert_eq!(abaddon[0].entry_type.as_deref(), Some("Application"));
        assert_eq!(abaddon[0].mime_types, ["x-scheme-handler/discord"]);
        assert_eq!(abaddon[0].categories, ["Network", "InstantMessaging"]);
        // An entry that says nothing about `NoDisplay` is displayable.
        assert!(!abaddon[0].no_display);

        // Packages commonly ship one real entry beside a pile of `NoDisplay`
        // stubs that exist only to claim MIME types.
        let krita = &info.packages["krita"].desktop_entries;
        assert!(!krita[0].no_display);
        assert!(krita[1].no_display);

        assert!(info.packages["hello"].desktop_entries.is_empty());
    }

    #[test]
    fn test_merge_desktop_index() {
        // The scanner reports one attribute per system, and a package can be
        // built for a system that ships no desktop entry for it.
        let json = r#"
        {
            "version": "2",
            "packages": {
                "abaddon.x86_64-linux": {
                    "status": "indexed",
                    "desktopEntries": [{ "icon": "abaddon" }],
                    "icons": { "abaddon": "0123456789abcdef0123456789abcdef.png" }
                },
                "abaddon.aarch64-darwin": {
                    "status": "no-entries",
                    "desktopEntries": [],
                    "icons": {}
                },
                "python3Packages.foo": {
                    "status": "no-entries",
                    "desktopEntries": [],
                    "icons": {}
                }
            }
        }
        "#;

        let merged = merge_desktop_index(serde_json::from_str(json).unwrap());

        assert_eq!(merged.len(), 2);
        assert_eq!(merged["abaddon"].desktop_entries.len(), 1);
        assert_eq!(
            merged["abaddon"].icons["abaddon"],
            "0123456789abcdef0123456789abcdef.png"
        );
        // A dot is only a system separator when what follows it is a system.
        assert!(merged.contains_key("python3Packages.foo"));
    }

    #[test]
    fn test_icon_theme_fill() {
        let theme = tempfile::tempdir().unwrap();
        let apps = theme.path().join("scalable/apps");
        std::fs::create_dir_all(&apps).unwrap();
        std::fs::write(apps.join("themed.svg"), b"<svg/>").unwrap();

        let entries: Vec<DesktopEntry> = ["themed", "unthemed", "already", "/nix/store/x/i.png"]
            .iter()
            .map(|icon| DesktopEntry {
                icon: Some(icon.to_string()),
                ..Default::default()
            })
            .collect();
        let supplied = PathBuf::from("/icons/already.png");
        let mut icons = HashMap::from([("already".to_string(), supplied.clone())]);

        IconTheme::new(theme.path().to_owned()).fill(&entries, &mut icons);

        assert_eq!(icons["themed"], apps.join("themed.svg"));
        // A name the theme does not carry stays absent rather than becoming a
        // link the frontend would render as a broken image.
        assert!(!icons.contains_key("unthemed"));
        // An icon the package supplied itself is the better one; keep it.
        assert_eq!(icons["already"], supplied);
        assert!(!icons.contains_key("/nix/store/x/i.png"));
    }

    #[test]
    fn test_icon_store_intern() {
        let dir = tempfile::tempdir().unwrap();
        let write = |name: &str, bytes: &[u8]| {
            let path = dir.path().join(name);
            std::fs::write(&path, bytes).unwrap();
            path
        };
        // Two packages shipping the same image under different file names, as
        // the icon theme case does: one file each, byte for byte identical.
        let png = write("one.png", b"\0\0\0");
        let same = write("another.png", b"\0\0\0");
        let svg = write("one.svg", b"<svg/>");
        let mut store = IconStore::default();

        let one = store.intern(HashMap::from([("a".to_string(), png.clone())]));
        let two = store.intern(HashMap::from([
            ("b".to_string(), same),
            ("c".to_string(), svg),
        ]));

        // The name follows the image, not the package, the icon name or the
        // file it was read from.
        assert_eq!(one["a"], two["b"]);
        assert_ne!(two["b"], two["c"]);
        // The source extension is kept, so the file is served as itself.
        assert!(one["a"].ends_with(".png"));
        assert!(two["c"].ends_with(".svg"));

        // A name travels on to the frontend build, which uses it as a path and
        // so checks it against `/^[0-9a-f]{32}\.[a-z]+$/` before writing it out.
        // A name that shape rejects is an icon no deploy serves, so it is
        // pinned on this side too rather than left to agree by accident.
        let lower_hex = |c: char| c.is_ascii_digit() || ('a'..='f').contains(&c);
        for file in [&one["a"], &two["b"], &two["c"]] {
            let (digest, extension) = file.split_once('.').unwrap();
            assert_eq!(digest.len(), 32);
            assert!(digest.chars().all(lower_hex));
            assert!(ICON_EXTENSIONS.contains(&extension));
        }

        // Two distinct images, stored once each however many packages point at
        // them, and reachable under exactly the names the packages now carry.
        assert_eq!(store.files.len(), 2);
        assert_eq!(store.files[&one["a"]], base64::encode(b"\0\0\0"));
        assert_eq!(store.files[&two["c"]], base64::encode("<svg/>"));

        // An image no browser renders is dropped from the package rather than
        // served under an extension that promises one it cannot read, and so is
        // a file that is named but not there.
        let three = store.intern(HashMap::from([
            ("d".to_string(), write("one.xpm", b"! XPM2")),
            ("e".to_string(), dir.path().join("absent.png")),
            ("f".to_string(), png),
        ]));
        assert!(!three.contains_key("d"));
        assert!(!three.contains_key("e"));
        assert_eq!(three["f"], one["a"]);
        assert_eq!(store.files.len(), 2);
    }

    #[test]
    fn test_icon_source() {
        let dir = Path::new("/icons");
        assert_eq!(
            icon_source(dir, "abc.png"),
            Some(PathBuf::from("/icons/abc.png"))
        );
        // The scanner writes bare file names, so anything that would read from
        // somewhere other than the directory it was pointed at is not one.
        for escape in ["../abc.png", "a/b.png", "/etc/passwd", "", "."] {
            assert_eq!(icon_source(dir, escape), None, "{escape}");
        }
    }

    #[test]
    fn test_localization_store() {
        // A name, a shared description of what the application is, and the
        // German for both. Firefox is called Firefox in German too.
        let entry = |name: &str, generic: &str, localized_name: &str| DesktopEntry {
            desktop_name: Some(name.to_string()),
            generic_name: Some(generic.to_string()),
            localized: HashMap::from([(
                "de".to_string(),
                LocalizedEntry {
                    desktop_name: Some(localized_name.to_string()),
                    generic_name: Some("Webbrowser".to_string()),
                    ..Default::default()
                },
            )]),
            ..Default::default()
        };

        let mut store = LocalizationStore::default();
        store.collect(&[
            entry("Firefox", "Web Browser", "Firefox"),
            // A second package translating a string the first one already did.
            entry("Konqueror", "Web Browser", "Konqueror"),
            // No translations at all, which is the overwhelming majority.
            DesktopEntry {
                desktop_name: Some("hello".to_string()),
                ..Default::default()
            },
        ]);

        // One English string is translated once for the whole corpus, not once
        // per package that carries it, and a translation identical to what it
        // translates costs bytes to say nothing.
        assert_eq!(
            store.locales["de"],
            BTreeMap::from([("Web Browser".to_string(), "Webbrowser".to_string())])
        );
        assert_eq!(store.locales.len(), 1);
    }

    #[test]
    #[ignore]
    fn test_get_nixpkgs_programs() {
        let nixpkgs = Nixpkgs {
            channel: "unstable".into(),
            git_ref: "".into(),
        };
        let programs = get_nixpkgs_programs(&nixpkgs).expect("get_nixpkgs_programs failed");
        assert!(
            !programs.is_empty(),
            "programs database should not be empty"
        );
    }
}
