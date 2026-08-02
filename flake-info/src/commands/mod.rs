mod dep_count;
mod nix_check_version;
mod nix_flake_attrs;
mod nix_flake_info;
mod nixpkgs_info;
mod repology;
pub use dep_count::get_nixpkgs_dep_counts;
pub use nix_check_version::{NixCheckError, check_nix_version};
pub use nix_flake_attrs::get_derivation_info;
pub use nix_flake_info::get_flake_info;
pub use nixpkgs_info::{
    get_darwin_options, get_home_manager_options, get_nixpkgs_info, get_nixpkgs_options,
    get_nixpkgs_package_services, get_nixpkgs_services,
};
pub use repology::{get_repology_repo_counts, load_repology_repo_counts};

use anyhow::{Context, Result, anyhow};
use command_run::{Command, LogTo, Output};
use lazy_static::lazy_static;
use log::info;
use std::path::PathBuf;

lazy_static! {
    static ref EXTRACT_SCRIPT: PathBuf = crate::DATADIR.join("commands/evalFlake.nix");
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

pub fn add_flake_arg(command: &mut Command, name: &str, flake_ref: &str) {
    let expr = format!("builtins.getFlake \"{}\"", flake_ref);
    command.add_args(["--arg", name, &expr].iter());
}

pub fn nix_eval_command(args: &[&str]) -> Command {
    let mut command = Command::with_args("nix", args.iter());
    command.add_arg_pair("-f", EXTRACT_SCRIPT.clone());
    command.enable_capture();
    command.log_to = LogTo::Log;
    command.log_output_on_error = true;
    command
}

/// How much of a `nix` trace to keep in the returned error. Group imports paste
/// the aggregated error verbatim into an auto-filed issue, and a full trace can
/// run to thousands of lines.
const STDERR_TAIL_LINES: usize = 40;

/// Run `command`, including its stderr in the error when it exits non-zero.
///
/// `command_run`'s own failure renders as just `command '...' failed: exit
/// status: 1` -- the actual `nix` message reaches only the log, so the error
/// that surfaces to the user carries no diagnostic information at all.
pub fn run_capturing_stderr(command: &mut Command) -> Result<Output> {
    let check = command.check;
    command.disable_check();
    let output = command.run();
    command.check = check;

    let output = output?;
    if output.status.success() {
        return Ok(output);
    }

    let stderr = output.stderr_string_lossy();
    let lines: Vec<&str> = stderr.lines().collect();
    let truncated = lines.len() > STDERR_TAIL_LINES;
    let tail = lines[lines.len().saturating_sub(STDERR_TAIL_LINES)..].join("\n");

    Err(anyhow!(
        "command '{}' failed: {}{}{}",
        command.command_line_lossy(),
        output.status,
        if truncated {
            format!(
                "\n[... {} earlier stderr lines omitted]",
                lines.len() - STDERR_TAIL_LINES
            )
        } else {
            String::new()
        },
        if tail.is_empty() {
            String::new()
        } else {
            format!("\n{}", tail)
        },
    ))
}
