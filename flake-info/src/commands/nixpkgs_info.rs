use anyhow::{Context, Result};
use serde::Deserialize;
use std::collections::{HashMap, HashSet};

use command_run::{Command, LogTo};

use crate::Source;
use crate::data::Nixpkgs;
use crate::data::import::{NixOption, NixpkgsEntry, Package};

/// Wrapper for the channel `packages.json` format.
#[derive(Deserialize)]
struct PackagesInfo {
    packages: HashMap<String, Package>,
}

pub fn get_nixpkgs_info(
    nixpkgs: &Source,
    attribute: &Option<String>,
    packages_json_url: &Option<String>,
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

    let response = reqwest::blocking::Client::new()
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

    Ok(attr_set
        .into_iter()
        .map(|(attribute, package)| {
            let programs = programs
                .remove(&attribute)
                .unwrap_or_default()
                .into_iter()
                .collect();
            let modular_services = package_services.remove(&attribute).unwrap_or_default();
            NixpkgsEntry::Derivation {
                attribute,
                package,
                programs,
                modular_services,
            }
        })
        .collect())
}

pub fn get_nixpkgs_package_services(nixpkgs: &Source) -> Result<HashMap<String, Vec<String>>> {
    let mut command = Command::with_args("nix", &["eval", "--json"]);
    command.add_arg_pair("-f", super::EXTRACT_SCRIPT.clone());
    command.add_arg_pair("-I", format!("nixpkgs={}", nixpkgs.to_flake_ref()));
    command.add_arg("nixos-package-services");

    command.enable_capture();
    command.log_to = LogTo::Log;
    command.log_output_on_error = true;

    let cow = command
        .run()
        .with_context(|| "Failed to gather modular service mapping for packages")?;

    let output = &*cow.stdout_string_lossy();
    let map: HashMap<String, Vec<String>> =
        serde_json::from_str(output).with_context(|| "Could not parse package-services map")?;
    Ok(map)
}

pub fn get_nixpkgs_programs(nixpkgs: &Nixpkgs) -> Result<HashMap<String, HashSet<String>>> {
    let mut command = Command::new("nix-instantiate");
    command.add_args(&[
        "--eval",
        "--json",
        "-I",
        format!("nixpkgs=channel:nixos-{}", nixpkgs.channel).as_str(),
        "--expr",
        "toString <nixpkgs/programs.sqlite>",
    ]);

    command.enable_capture();
    command.log_to = LogTo::Log;
    command.log_output_on_error = true;

    let cow = command
        .run()
        .with_context(|| "Failed to gather information about nixpkgs programs")?;

    let output = &*cow.stdout_string_lossy();
    let programs_db: &str = serde_json::from_str(output)?;
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

pub fn get_nixpkgs_options(nixpkgs: &Source) -> Result<Vec<NixpkgsEntry>> {
    let mut command = Command::with_args("nix", &["eval", "--json"]);
    command.add_arg_pair("-f", super::EXTRACT_SCRIPT.clone());
    command.add_arg_pair("-I", format!("nixpkgs={}", nixpkgs.to_flake_ref()));
    command.add_arg("nixos-options");

    command.enable_capture();
    command.log_to = LogTo::Log;
    command.log_output_on_error = true;

    let cow = command
        .run()
        .with_context(|| "Failed to gather information about nixpkgs options")?;

    let output = &*cow.stdout_string_lossy();
    let de = &mut serde_json::Deserializer::from_str(output);
    let attr_set: Vec<NixOption> =
        serde_path_to_error::deserialize(de).with_context(|| "Could not parse options")?;

    Ok(attr_set.into_iter().map(NixpkgsEntry::Option).collect())
}

pub fn get_nixpkgs_services(nixpkgs: &Source) -> Result<Vec<NixpkgsEntry>> {
    let mut command = Command::with_args("nix", &["eval", "--json"]);
    command.add_arg_pair("-f", super::EXTRACT_SCRIPT.clone());
    command.add_arg_pair("-I", format!("nixpkgs={}", nixpkgs.to_flake_ref()));
    command.add_arg("nixos-services");

    command.enable_capture();
    command.log_to = LogTo::Log;
    command.log_output_on_error = true;

    let cow = command
        .run()
        .with_context(|| "Failed to gather information about nixpkgs modular services")?;

    let output = &*cow.stdout_string_lossy();
    let de = &mut serde_json::Deserializer::from_str(output);
    let attr_set: Vec<NixOption> =
        serde_path_to_error::deserialize(de).with_context(|| "Could not parse services")?;

    Ok(attr_set.into_iter().map(NixpkgsEntry::Service).collect())
}

/// Home-manager flake reference used to evaluate HM options alongside
/// each nixpkgs channel import.
const HOME_MANAGER_FLAKE_REF: &str = "github:nix-community/home-manager";

pub fn get_home_manager_options(nixpkgs: &Source) -> Result<Vec<NixpkgsEntry>> {
    let mut command = Command::with_args("nix", &["eval", "--json", "--no-write-lock-file"]);
    command.add_arg_pair("-f", super::EXTRACT_SCRIPT.clone());
    command.add_arg_pair("-I", format!("nixpkgs={}", nixpkgs.to_flake_ref()));
    command.add_args(["--override-flake", "input-flake", HOME_MANAGER_FLAKE_REF].iter());
    command.add_arg("home-manager-options");

    command.enable_capture();
    command.log_to = LogTo::Log;
    command.log_output_on_error = true;

    let cow = command
        .run()
        .with_context(|| "Failed to gather information about home-manager options")?;

    let output = &*cow.stdout_string_lossy();
    let de = &mut serde_json::Deserializer::from_str(output);
    let attr_set: Vec<NixOption> = serde_path_to_error::deserialize(de)
        .with_context(|| "Could not parse home-manager options")?;

    Ok(attr_set
        .into_iter()
        .map(NixpkgsEntry::HomeManagerOption)
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
}
