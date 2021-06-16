use anyhow::{Context, Result};
use std::io::Write;
use std::{collections::HashMap, fmt::Display, fs::File};

use command_run::Command;
use log::debug;

use crate::data::import::{NixpkgsEntry, Package};

const NIXPKGS_SCRIPT: &str = include_str!("packages-config.nix");

pub fn get_nixpkgs_info<T: AsRef<str> + Display>(nixpkgs_channel: T) -> Result<Vec<NixpkgsEntry>> {
    let script_dir = tempfile::tempdir()?;
    let script_path = script_dir.path().join("packages-config.nix");
    writeln!(File::create(&script_path)?, "{}", NIXPKGS_SCRIPT)?;

    let mut command = Command::new("nix-env");
    let command = command.enable_capture();
    let command = command.add_args(&[
        "-f",
        "<nixpkgs>",
        "-I", nixpkgs_channel.as_ref(),
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
                .map(|(attribute, package)| NixpkgsEntry { attribute, package })
                .collect())
        });

    parsed
}
