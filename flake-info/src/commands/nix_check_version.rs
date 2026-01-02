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

fn compare_nix_versions(min_version: &str, actual_version: &str) -> Result<(), NixCheckError> {
    let nix_version_requirement = VersionReq::parse(&format!(">={}", min_version))?;

    let nix_version = Version::parse(
        actual_version
            .replace("pre", ".0-pre")
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

pub fn check_nix_version(min_version: &str) -> Result<(), NixCheckError> {
    info!("Checking nix version");

    let mut command =
        Command::with_args("nix", &["eval", "--raw", "--expr", "builtins.nixVersion"]);
    command.log_command = false;
    command.enable_capture();
    let output = command.run()?;
    return compare_nix_versions(
        min_version,
        output.stdout_string_lossy().into_owned().as_str(),
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ok() {
        assert!(compare_nix_versions("2.4.0", "2.3.0").is_err());
        compare_nix_versions("2.4.0", "2.4.0").expect("Exactly matching version");
        compare_nix_versions("2.4.0", "2.14.0").expect("Other matching version");
        compare_nix_versions("2.4.0", "2.33pre20251107_6a3e3982")
            .expect("Matching prerelease version");
    }
}
