use anyhow::{Context, Result};
use semver::{Version, VersionReq};
use serde_json::Deserializer;
use std::io::Write;
use std::{process::exit, collections::HashMap, fmt::Display, fs::File};

use command_run::{Command, LogTo};
use log::{debug, error};

use crate::data::import::{NixOption, NixpkgsEntry, Package};

const FLAKE_INFO_SCRIPT: &str = include_str!("flake_info.nix");

pub fn get_nixpkgs_info<T: AsRef<str> + Display>(nixpkgs_channel: T) -> Result<Vec<NixpkgsEntry>> {
    let nix_version_requirement = VersionReq::parse(">=2.7.0")?; // we need PRs #5878 and #5922 for package outputs
    let mut command = Command::with_args("nix", &["eval", "--raw", "--expr", "builtins.nixVersion"]);
    command.log_command = false;
    command.enable_capture();
    let output = command.run()?;
    let nix_version = Version::parse(
        output.stdout_string_lossy()
              .split(|c: char| c != '.' && !c.is_ascii_digit())
              .next()
              .unwrap()
    )?;
    if !nix_version_requirement.matches(&nix_version) {
        error!("nix doesn't match version requirement {}", nix_version_requirement);
        exit(1);
    }

    let mut command = Command::new("nix-env");
    command.add_args(&[
        "-f",
        "<nixpkgs>",
        "-I",
        format!("nixpkgs={}", nixpkgs_channel.as_ref()).as_str(),
        "--arg",
        "config",
        "import <nixpkgs/pkgs/top-level/packages-config.nix>",
        "-qa",
        "--meta",
        "--out-path",
        "--json",
    ]);

    // Nix might fail to evaluate some disallowed packages
    let mut env = HashMap::new();
    env.insert("NIXPKGS_ALLOW_BROKEN".into(), "1".into());
    env.insert("NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM".into(), "1".into());
    env.insert("NIXPKGS_ALLOW_UNFREE".into(), "1".into());
    env.insert("NIXPKGS_ALLOW_INSECURE".into(), "1".into());
    command.env = env;

    command.enable_capture();
    command.log_to = LogTo::Log;
    command.log_output_on_error = true;

    let parsed: Result<Vec<NixpkgsEntry>> = command
        .run()
        .with_context(|| {
            format!(
                "Failed to gather information about nixpkgs {}",
                nixpkgs_channel.as_ref()
            )
        })
        .and_then(|o| {
            let output = &*o.stdout_string_lossy();
            let de = &mut Deserializer::from_str(output);
            let attr_set: HashMap<String, Package> =
                serde_path_to_error::deserialize(de).with_context(|| "Could not parse packages")?;
            Ok(attr_set
                .into_iter()
                .map(|(attribute, package)| NixpkgsEntry::Derivation { attribute, package })
                .collect())
        });

    parsed
}

pub fn get_nixpkgs_options<T: AsRef<str> + Display>(
    nixpkgs_channel: T,
) -> Result<Vec<NixpkgsEntry>> {
    let script_dir = tempfile::tempdir()?;
    let script_path = script_dir.path().join("flake_info.nix");
    writeln!(File::create(&script_path)?, "{}", FLAKE_INFO_SCRIPT)?;

    let mut command = Command::new("nix");
    command.add_args(&[
        "eval",
        "--json",
        "-f",
        script_path.to_str().unwrap(),
        "-I",
        format!("nixpkgs={}", nixpkgs_channel.as_ref()).as_str(),
        "--arg",
        "flake",
        nixpkgs_channel.as_ref(),
        "nixos-options",
    ]);

    // Nix might fail to evaluate some options that reference disallowed packages
    let mut env = HashMap::new();
    env.insert("NIXPKGS_ALLOW_BROKEN".into(), "1".into());
    env.insert("NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM".into(), "1".into());
    env.insert("NIXPKGS_ALLOW_UNFREE".into(), "1".into());
    env.insert("NIXPKGS_ALLOW_INSECURE".into(), "1".into());
    command.env = env;

    command.enable_capture();
    command.log_to = LogTo::Log;
    command.log_output_on_error = true;

    let parsed = command.run().with_context(|| {
        format!(
            "Failed to gather information about nixpkgs {}",
            nixpkgs_channel.as_ref()
        )
    });

    if let Err(ref e) = parsed {
        error!("Command error: {}", e);
    }

    parsed.and_then(|o| {
        let output = &*o.stdout_string_lossy();
        let de = &mut Deserializer::from_str(output);
        let attr_set: Vec<NixOption> =
            serde_path_to_error::deserialize(de).with_context(|| "Could not parse options")?;
        Ok(attr_set.into_iter().map(NixpkgsEntry::Option).collect())
    })
}
