mod nix_check_version;
mod nix_flake_attrs;
mod nix_flake_info;
mod nixpkgs_info;
pub use nix_check_version::{NixCheckError, check_nix_version};
pub use nix_flake_attrs::get_derivation_info;
pub use nix_flake_info::get_flake_info;
pub use nixpkgs_info::{get_nixpkgs_info, get_nixpkgs_options};

use anyhow::{Context, Result};
use command_run::{Command, LogTo};
use lazy_static::lazy_static;
use log::info;
use std::path::PathBuf;

lazy_static! {
    static ref EXTRACT_SCRIPT: PathBuf = crate::DATADIR.join("commands/flake_info.nix");
}

pub fn run_garbage_collection() -> Result<()> {
    info!("Running nix garbage collection");
    let mut command = Command::new("nix-collect-garbage");
    command.log_to = LogTo::Log;
    command.log_output_on_error = true;

    command
        .run()
        .with_context(|| "Failed to run garbage collection")?;

    Ok(())
}
