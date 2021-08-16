use anyhow::{Context, Result};
use std::io::Write;
use std::{collections::HashMap, fmt::Display, fs::File};

use command_run::Command;
use log::{debug, error};

use crate::data::import::{NixOption, NixpkgsEntry, Package};

const NIXPKGS_SCRIPT: &str = include_str!("packages-config.nix");
const FLAKE_INFO_SCRIPT: &str = include_str!("flake_info.nix");

pub fn get_nixpkgs_info<T: AsRef<str> + Display>(nixpkgs_channel: T) -> Result<Vec<NixpkgsEntry>> {
    let script_dir = tempfile::tempdir()?;
    let script_path = script_dir.path().join("packages-config.nix");
    writeln!(File::create(&script_path)?, "{}", NIXPKGS_SCRIPT)?;

    let mut command = Command::new("nix-env");
    let command = command.enable_capture();
    let command = command.add_args(&[
        "-f",
        "<nixpkgs>",
        "-I",
        format!("nixpkgs={}", nixpkgs_channel.as_ref()).as_str(),
        "--arg",
        "config",
        format!("import {}", script_path.to_str().unwrap()).as_str(),
        "-qa",
        "--json",
    ]);

    let parsed: Result<Vec<NixpkgsEntry>> = command
        .run()
        .with_context(|| {
            format!(
                "Failed to gather information about nixpkgs {}",
                nixpkgs_channel.as_ref()
            )
        })
        .and_then(|o| {
            debug!("stderr: {}", o.stderr_string_lossy());
            let attr_set: HashMap<String, Package> =
                serde_json::de::from_str(&o.stdout_string_lossy())?;
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
    let command = command.enable_capture();
    let mut command = command.add_args(&[
        "eval",
        "--json",
        "-f",
        script_path.to_str().unwrap(),
        "--arg",
        "flake",
        nixpkgs_channel.as_ref(),
        "nixos-options",
    ]);

    // Nix might fail to evaluate some options that reference insecure packages
    let mut env = HashMap::new();
    env.insert("NIXPKGS_ALLOW_INSECURE".into(), "1".into());
    env.insert("NIXPKGS_ALLOW_UNFREE".into(), "1".into());

    command.env = env;

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
        debug!("stderr: {}", o.stderr_string_lossy());
        let attr_set: Vec<NixOption> = serde_json::de::from_str(&o.stdout_string_lossy())?;
        Ok(attr_set.into_iter().map(NixpkgsEntry::Option).collect())
    })
}
