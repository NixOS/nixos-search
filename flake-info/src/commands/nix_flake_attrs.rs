use crate::data::import::{FlakeEntry, Kind};
use anyhow::{Context, Result};
use command_run::{Command, LogTo};
use log::debug;
use serde_json::Deserializer;
use std::fmt::Display;
use std::fs::File;
use std::io::Write;
use std::path::PathBuf;

const SCRIPT: &str = include_str!("flake_info.nix");
const ARGS: [&str; 3] = ["eval", "--json", "--no-write-lock-file"];

/// Uses `nix` to fetch the provided flake and read general information
/// about it using `nix flake info`
pub fn get_derivation_info<T: AsRef<str> + Display>(
    flake_ref: T,
    kind: Kind,
    temp_store: bool,
    extra: &[String],
) -> Result<Vec<FlakeEntry>> {
    let script_dir = tempfile::tempdir()?;
    let script_path = script_dir.path().join("extract.nix");
    writeln!(File::create(&script_path)?, "{}", SCRIPT)?;

    let mut command = Command::with_args("nix", ARGS.iter());
    command.add_arg_pair("-f", script_path.as_os_str());
    command.add_args(["--override-flake", "input-flake", flake_ref.as_ref()].iter());
    command.add_args(["--argstr", "flake", flake_ref.as_ref()].iter());
    command.add_arg(kind.as_ref());
    if temp_store {
        let temp_store_path = PathBuf::from("/tmp/flake-info-store");
        if !temp_store_path.exists() {
            std::fs::create_dir_all(&temp_store_path)
                .with_context(|| "Couldn't create temporary store path")?;
        }
        command.add_arg_pair("--store", temp_store_path.canonicalize()?);
    }
    command.add_args(extra);
    command.enable_capture();
    command.log_to = LogTo::Log;
    command.log_output_on_error = true;

    let parsed: Result<Vec<FlakeEntry>> = command
        .run()
        .with_context(|| format!("Failed to gather information about {}", flake_ref))
        .and_then(|o| {
            let output = &*o.stdout_string_lossy();
            let de = &mut Deserializer::from_str(output);
            serde_path_to_error::deserialize(de)
                .with_context(|| format!("Failed to analyze flake {}", flake_ref))
        });
    parsed
}
