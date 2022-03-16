use anyhow::{Context, Result};
use command_run::{Command, LogTo};
use std::fmt::Display;
use std::path::PathBuf;

use crate::data::Flake;

/// Uses `nix` to fetch the provided flake and read general information
/// about it using `nix flake metadata`
pub fn get_flake_info<T: AsRef<str> + Display>(
    flake_ref: T,
    temp_store: bool,
    extra: &[String],
) -> Result<Flake> {
    let args = ["flake", "metadata", "--json", "--no-write-lock-file"];
    let mut command = Command::with_args("nix", args);
    command.add_arg(flake_ref.as_ref());
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

    command
        .run()
        .with_context(|| format!("Failed to gather information about {}", flake_ref))
        .and_then(|o| {
            let deserialized: Result<Flake, _> =
                serde_json::de::from_str(o.stdout_string_lossy().to_string().as_str());
            Ok(deserialized?.resolve_name())
        })
}
