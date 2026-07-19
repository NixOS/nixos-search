use std::collections::{HashMap, HashSet};

use anyhow::{Context, Result};
use command_run::{Command, LogTo};
use log::info;
use serde::Deserialize;

use crate::data::Nixpkgs;

/// One line of `nix-eval-jobs --show-input-drvs` output. Eval errors have no `drvPath`.
#[derive(Debug, Deserialize)]
struct EvalJob {
    attr: String,
    #[serde(rename = "drvPath")]
    drv_path: Option<String>,
    #[serde(rename = "inputDrvs", default)]
    input_drvs: HashMap<String, Vec<String>>,
}

/// Direct reverse-dependency count per top-level nixpkgs attribute, used as
/// the `package_dep_count` popularity signal.
///
/// Evaluates only x86_64-linux since the graph is nearly identical across
/// systems. Workers and memory are sized for GitHub-hosted runners.
pub fn get_nixpkgs_dep_counts(nixpkgs: &Nixpkgs) -> Result<HashMap<String, u64>> {
    let flake_ref = format!(
        "github:NixOS/nixpkgs/{}#legacyPackages.x86_64-linux",
        nixpkgs.git_ref
    );
    info!("Computing reverse-dependency counts from {}", flake_ref);

    // Instantiation is required for input drvs. Use a throwaway chroot store
    // so the drvs stay out of the real store and are cleaned up afterwards.
    let store_dir = tempfile::Builder::new()
        .prefix("flake-info-dep-count-store")
        .tempdir()
        .with_context(|| "Failed to create temporary store directory")?;
    let gc_roots_dir = store_dir.path().join("gc-roots");

    let mut command = Command::with_args(
        "nix-eval-jobs",
        [
            "--show-input-drvs",
            "--workers",
            "2",
            "--max-memory-size",
            "3072",
            "--flake",
            &flake_ref,
        ]
        .iter(),
    );
    command.add_arg_pair("--store", store_dir.path());
    command.add_arg_pair("--gc-roots-dir", gc_roots_dir);
    command.enable_capture();
    command.log_to = LogTo::Log;
    // Output is huge. Don't echo it into the log on failure.
    command.log_output_on_error = false;

    let output = command
        .run()
        .with_context(|| "Failed to run nix-eval-jobs for dependency counts");

    // Nix makes store directories read-only, which breaks TempDir removal.
    let mut chmod = Command::with_args("chmod", ["-R", "u+w"].iter());
    chmod.add_arg(store_dir.path());
    chmod.log_to = LogTo::Log;
    let _ = chmod.run();

    let jobs = parse_eval_jobs(&output?.stdout_string_lossy())?;
    Ok(count_direct_reverse_deps(&jobs))
}

fn parse_eval_jobs(output: &str) -> Result<Vec<EvalJob>> {
    output
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            serde_json::from_str(line)
                .with_context(|| format!("Could not parse nix-eval-jobs output line: {}", line))
        })
        .collect()
}

/// Count how many other derivations use each attribute's derivation as a
/// direct input. Inputs without a top-level attribute are ignored. Aliases
/// sharing a drv get the same count and are only counted once as dependents.
fn count_direct_reverse_deps(jobs: &[EvalJob]) -> HashMap<String, u64> {
    let mut drv_to_attrs: HashMap<&str, Vec<&str>> = HashMap::new();
    for job in jobs {
        if let Some(drv) = &job.drv_path {
            drv_to_attrs.entry(drv).or_default().push(&job.attr);
        }
    }

    let mut drv_counts: HashMap<&str, u64> = HashMap::new();
    let mut seen_drvs: HashSet<&str> = HashSet::new();
    for job in jobs {
        let Some(drv) = job.drv_path.as_deref() else {
            continue;
        };
        if !seen_drvs.insert(drv) {
            continue;
        }
        for input in job.input_drvs.keys() {
            if input != drv && drv_to_attrs.contains_key(input.as_str()) {
                *drv_counts.entry(input.as_str()).or_default() += 1;
            }
        }
    }

    drv_counts
        .into_iter()
        .flat_map(|(drv, count)| {
            drv_to_attrs[drv]
                .iter()
                .map(move |attr| ((*attr).to_string(), count))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_count_direct_reverse_deps() {
        let output = r#"
            {"attr":"openssl","drvPath":"/nix/store/aaa-openssl.drv","inputDrvs":{"/nix/store/zzz-perl.drv":["out"]}}
            {"attr":"curl","drvPath":"/nix/store/bbb-curl.drv","inputDrvs":{"/nix/store/aaa-openssl.drv":["out","dev"],"/nix/store/xxx-patch.drv":["out"]}}
            {"attr":"git","drvPath":"/nix/store/ccc-git.drv","inputDrvs":{"/nix/store/aaa-openssl.drv":["dev"],"/nix/store/bbb-curl.drv":["dev"]}}
            {"attr":"curlAlias","drvPath":"/nix/store/bbb-curl.drv","inputDrvs":{"/nix/store/aaa-openssl.drv":["out"]}}
            {"attr":"broken","error":"evaluation failed"}
        "#;
        let jobs = parse_eval_jobs(output).unwrap();
        let counts = count_direct_reverse_deps(&jobs);

        assert_eq!(counts.get("openssl"), Some(&2));
        assert_eq!(counts.get("curl"), Some(&1));
        assert_eq!(counts.get("curlAlias"), Some(&1));
        assert_eq!(counts.get("git"), None);
        assert_eq!(counts.get("broken"), None);
        assert_eq!(counts.len(), 3);
    }

    #[test]
    fn test_parse_error_is_reported() {
        assert!(parse_eval_jobs("not json").is_err());
    }
}
