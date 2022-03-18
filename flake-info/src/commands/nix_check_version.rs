use command_run::Command;
use log::info;
use semver::{Version, VersionReq};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum NixCheckError {
    #[error("Installed nix doesn't match version requirement: {0} (required {1})")]
    IncompatibleNixVersion(Version, VersionReq),

    #[error("SemVer error (this should not occur, please file a bug report): {0}")]
    CheckError(#[from] semver::Error),

    #[error("Failed to run nix command: {0}")]
    CommandError(#[from] command_run::Error),
}

pub fn check_nix_version(min_version: &str) -> Result<(), NixCheckError> {
    info!("Checking nix version");

    let nix_version_requirement = VersionReq::parse(&format!(">={}", min_version))?;

    let mut command =
        Command::with_args("nix", &["eval", "--raw", "--expr", "builtins.nixVersion"]);
    command.log_command = false;
    command.enable_capture();
    let output = command.run()?;
    let nix_version = Version::parse(
        output
            .stdout_string_lossy()
            .split(|c: char| c != '.' && !c.is_ascii_digit())
            .next()
            .unwrap(),
    )?;
    if !nix_version_requirement.matches(&nix_version) {
        return Err(NixCheckError::IncompatibleNixVersion(
            nix_version,
            nix_version_requirement,
        ));
    }
    Ok(())
}
