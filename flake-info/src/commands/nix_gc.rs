use anyhow::{Context, Result};
use log::warn;
use std::{
    path::{self, PathBuf},
    process::Command,
};
use thiserror::Error;

#[derive(Error, Debug)]
pub enum GCError {
    #[error("Unexpected exit status: {0}")]
    ExitStatusError(String),
}

pub fn run_gc() -> Result<()> {
    let temp_store_path = PathBuf::from("/tmp/flake-info-store");
    if !temp_store_path.exists() {
        warn!("Temporary store path does not exist, was a temporary store used?");
        return Ok(());
    }

    let mut command = Command::new("nix-store");
    command.args(&[
        "--gc",
        "--store",
        temp_store_path.canonicalize()?.to_str().unwrap(),
    ]);

    dbg!(&command);

    let mut child = command
        .spawn()
        .with_context(|| "failed to start `nix-store gc` subprocess")?;

    let result = child.wait()?;

    if !result.success() {
        return Err(GCError::ExitStatusError(format!("Code: {}", result.code().unwrap())).into());
    }

    std::fs::remove_dir_all(temp_store_path).with_context(|| "failed to clean up temp dir")?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_gc() {
        run_gc().unwrap();
    }
}
