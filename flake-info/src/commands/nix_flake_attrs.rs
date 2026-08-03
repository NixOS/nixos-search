use crate::data::import::{FlakeEntry, Kind};
use anyhow::{Context, Result};
use std::collections::HashMap;
use std::fmt::Display;
use std::path::PathBuf;

const SELF_FLAKE_REF: &str = env!("SELF_FLAKE_REF");

const ARGS: [&str; 4] = [
    "eval",
    "--json",
    "--no-allow-import-from-derivation",
    "--no-write-lock-file",
];

pub fn get_derivation_info<T: AsRef<str> + Display>(
    flake_ref: T,
    _kind: Kind,
    temp_store: bool,
    extra: &[String],
) -> Result<Vec<FlakeEntry>> {
    let expr = format!(
        "((builtins.getFlake \"{self}\").lib.evalFlake {{ targetFlake = \"{target}\"; }}).manifest",
        self = SELF_FLAKE_REF,
        target = flake_ref.as_ref(),
    );
    let mut command = super::nix_eval_command(&ARGS);
    command
        .env
        .insert("NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM".into(), "1".into());
    command.add_args(["--expr", &expr].iter());
    if temp_store {
        let temp_store_path = PathBuf::from("/tmp/flake-info-store");
        if !temp_store_path.exists() {
            std::fs::create_dir_all(&temp_store_path)
                .with_context(|| "Couldn't create temporary store path")?;
        }
        command.add_arg_pair("--store", temp_store_path.canonicalize()?);
    }
    command.add_args(extra);

    super::run_capturing_stderr(&mut command)
        .with_context(|| format!("Failed to gather information about {}", flake_ref))
        .and_then(|o| {
            let output = &*o.stdout_string_lossy();
            parse_manifest_tree(output)
                .with_context(|| format!("Failed to analyze flake {}", flake_ref))
        })
}

fn parse_manifest_tree(json_str: &str) -> Result<Vec<FlakeEntry>> {
    let raw_tree: HashMap<String, serde_json::Value> = serde_json::from_str(json_str)?;
    let mut entries = Vec::new();

    for (schema_key, schema_val) in raw_tree {
        if let Some(sys_map) = schema_val.as_object() {
            for (system, sys_node) in sys_map {
                if let Some(children) = sys_node.get("children").and_then(|c| c.as_object()) {
                    for (attr_name, item_node) in children {
                        if schema_key == "packages" || schema_key == "legacyPackages" {
                            let name = item_node
                                .get("name")
                                .and_then(|v| v.as_str())
                                .unwrap_or(attr_name)
                                .to_string();
                            let version = item_node
                                .get("version")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string();
                            let default_output = item_node
                                .get("outputName")
                                .and_then(|v| v.as_str())
                                .unwrap_or("out")
                                .to_string();
                            let outputs = item_node
                                .get("outputs")
                                .and_then(|v| v.as_array())
                                .map(|arr| {
                                    arr.iter()
                                        .filter_map(|x| x.as_str().map(String::from))
                                        .collect()
                                })
                                .unwrap_or_else(|| vec!["out".to_string()]);
                            let description = item_node
                                .get("meta")
                                .and_then(|m| m.get("description"))
                                .and_then(|v| v.as_str())
                                .map(String::from);

                            entries.push(FlakeEntry::Package {
                                attribute_name: attr_name.clone(),
                                name,
                                version,
                                platforms: vec![system.clone()],
                                outputs,
                                default_output,
                                description,
                                long_description: None,
                                license: None,
                            });
                        } else if schema_key == "apps" {
                            let bin = item_node
                                .get("program")
                                .or_else(|| item_node.get("bin"))
                                .and_then(|v| v.as_str())
                                .map(PathBuf::from);

                            entries.push(FlakeEntry::App {
                                bin,
                                attribute_name: attr_name.clone(),
                                platforms: vec![system.clone()],
                                app_type: Some("app".to_string()),
                            });
                        }
                    }
                }
            }
        }
    }

    Ok(entries)
}
