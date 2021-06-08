use std::{fmt::Display, fs::File};
use anyhow::{Context, Result};
use std::io::Write;


use command_run::Command;
use log::debug;

use crate::data::Derivation;

const NIXPKGS_SCRIPT: &str = include_str!("packages-config.nix");


pub fn get_nixpkgs_info<T: AsRef<str> + Display>(nixpkgs_flake_ref: T) ->  Result<Vec<Derivation>> {
    let script_dir = tempfile::tempdir()?;
    let script_path = script_dir.path().join("packages-config.nix");
    writeln!(File::create(&script_path)?, "{}", NIXPKGS_SCRIPT)?;

    let mut command = Command::new("nix-env");
    let command = command.enable_capture();
    let command = command.add_args(&[
    "-f", "<nixpkgs>",
    "-I", nixpkgs_flake_ref.as_ref(),
    "--arg", "config", format!("import {}", script_path.to_str().unwrap()).as_str(),
    "-qa",
    "--json"]);

    let parsed: Result<Vec<Derivation>> = command
        .run()
        .with_context(|| format!("Failed to gather information about nixpkgs {}", nixpkgs_flake_ref.as_ref()))
        .and_then(|o| {
            debug!("stderr: {}", o.stderr_string_lossy());
            Ok(serde_json::de::from_str(&o.stdout_string_lossy())?)
        });

    parsed

}
