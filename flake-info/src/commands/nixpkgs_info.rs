use anyhow::{Context, Result};
use command_run::{Command, LogTo};
use serde::Deserialize;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use crate::Source;
use crate::data::Nixpkgs;
use crate::data::import::{NixOption, NixpkgsEntry, Package};

/// Wrapper for the channel `packages.json` format.
#[derive(Deserialize)]
struct PackagesInfo {
    packages: HashMap<String, Package>,
}

fn fetch_channel_json<T: serde::de::DeserializeOwned>(
    channel: &str,
    filename: &str,
    override_url: &Option<String>,
) -> Result<T> {
    let url = override_url
        .clone()
        .unwrap_or_else(|| format!("https://channels.nixos.org/nixos-{channel}/{filename}"));
    log::info!("Fetching {filename} from {url}");

    let fetch_bytes = async {
        let res = reqwest::get(&url)
            .await
            .with_context(|| format!("Failed to download {url}"))?
            .error_for_status()
            .with_context(|| format!("HTTP error fetching {url}"))?;
        res.bytes()
            .await
            .with_context(|| format!("Failed to read body from {url}"))
    };

    let bytes = if let Ok(handle) = tokio::runtime::Handle::try_current() {
        tokio::task::block_in_place(|| handle.block_on(fetch_bytes))?
    } else {
        tokio::runtime::Runtime::new()?.block_on(fetch_bytes)?
    };

    serde_json::from_slice(&bytes).with_context(|| format!("Could not parse channel {filename}"))
}

pub fn get_nixpkgs_info(
    nixpkgs: &Source,
    attribute: &Option<String>,
    packages_json_url: &Option<String>,
    repology_counts_file: &Option<PathBuf>,
) -> Result<Vec<NixpkgsEntry>> {
    let nixpkgs = match nixpkgs {
        Source::Nixpkgs(nixpkgs) => nixpkgs,
        other => anyhow::bail!(
            "package import requires a nixpkgs channel, got {}",
            other.to_flake_ref(),
        ),
    };

    let info: PackagesInfo =
        fetch_channel_json(&nixpkgs.channel, "packages.json.br", packages_json_url)?;

    let attr_set: HashMap<String, Package> = match attribute {
        Some(prefix) => info
            .packages
            .into_iter()
            .filter(|(key, _)| key.starts_with(prefix.as_str()))
            .collect(),
        None => info.packages,
    };

    let mut programs = get_nixpkgs_programs(nixpkgs)?;
    let mut package_services: HashMap<String, Vec<String>> = HashMap::new();
    // Skip the slow eval when only importing a single attribute.
    let dep_counts = if attribute.is_none() {
        super::get_nixpkgs_dep_counts(nixpkgs)?
    } else {
        HashMap::new()
    };
    let repology_counts = if attribute.is_some() {
        HashMap::new()
    } else {
        resolve_repology_counts(repology_counts_file)
    };

    Ok(attr_set
        .into_iter()
        .map(|(attribute, package)| {
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
        .collect())
}

/// Repology counts for a full import: from a pre-fetched file when provided
/// (missing/unreadable -> warn + empty, per the daily-cache design), otherwise
/// a live best-effort crawl (local/dev/manual and archive/group paths).
fn resolve_repology_counts(file: &Option<PathBuf>) -> HashMap<String, u64> {
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
        None => super::get_repology_repo_counts().unwrap_or_else(|err| {
            log::warn!("Skipping Repology repository counts: {:#}", err);
            HashMap::new()
        }),
    }
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

#[derive(Deserialize)]
struct ChannelOption {
    #[serde(default)]
    declarations: Vec<String>,
    description: Option<crate::data::import::DocString>,
    #[serde(rename = "type")]
    option_type: Option<String>,
    #[serde(deserialize_with = "crate::data::import::optional_field", default)]
    default: Option<crate::data::import::DocValue>,
    #[serde(deserialize_with = "crate::data::import::optional_field", default)]
    example: Option<crate::data::import::DocValue>,
}

pub fn get_nixpkgs_options(
    nixpkgs: &Source,
    options_json_url: &Option<String>,
) -> Result<Vec<NixpkgsEntry>> {
    let channel = match nixpkgs {
        Source::Nixpkgs(src) => &src.channel,
        other => anyhow::bail!(
            "option import requires nixpkgs, got {}",
            other.to_flake_ref()
        ),
    };

    let raw_map: HashMap<String, ChannelOption> =
        fetch_channel_json(channel, "options.json.br", options_json_url)?;

    Ok(raw_map
        .into_iter()
        .map(|(name, item)| {
            NixpkgsEntry::Option(NixOption {
                declarations: item.declarations,
                description: item.description,
                name,
                option_type: item.option_type,
                default: item.default,
                example: item.example,
                flake: None,
            })
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

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
