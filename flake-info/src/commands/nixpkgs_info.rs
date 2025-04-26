use anyhow::{Context, Result};
use serde_json::Deserializer;
use std::collections::{HashMap, HashSet};

use command_run::{Command, LogTo};

use crate::data::import::{NixOption, NixpkgsEntry, Package};
use crate::data::Nixpkgs;
use crate::Source;

pub fn get_nixpkgs_info(nixpkgs: &Source, attribute: &Option<String>) -> Result<Vec<NixpkgsEntry>> {
    let mut command = Command::new("nix-env");
    command.add_args(&[
        "--json",
        "-f",
        "<nixpkgs>",
        "-I",
        format!("nixpkgs={}", nixpkgs.to_flake_ref()).as_str(),
        "--arg",
        "config",
        "import <nixpkgs/pkgs/top-level/packages-config.nix>",
        "-qa",
    ]);
    match attribute {
        Some(attr) => { command.add_arg(attr); },
        None => {},
    }
    command.add_arg("--meta");

    command.enable_capture();
    command.log_to = LogTo::Log;
    command.log_output_on_error = true;

    let cow = command
        .run()
        .with_context(|| "Failed to gather information about nixpkgs packages")?;

    let output = &*cow.stdout_string_lossy();
    let de = &mut Deserializer::from_str(output);
    let attr_set: HashMap<String, Package> =
        serde_path_to_error::deserialize(de).with_context(|| "Could not parse packages")?;

    let mut programs = match nixpkgs {
        Source::Nixpkgs(nixpkgs) => get_nixpkgs_programs(nixpkgs)?,
        _ => Default::default(),
    };

    Ok(attr_set
        .into_iter()
        .map(|(attribute, package)| {
            let programs = programs
                .remove(&attribute)
                .unwrap_or_default()
                .into_iter()
                .collect();
            NixpkgsEntry::Derivation {
                attribute,
                package,
                programs,
            }
        })
        .collect())
}

pub fn get_nixpkgs_programs(nixpkgs: &Nixpkgs) -> Result<HashMap<String, HashSet<String>>> {
    let mut command = Command::new("nix-instantiate");
    command.add_args(&[
        "--eval",
        "--json",
        "-I",
        format!("nixpkgs=channel:nixos-{}", nixpkgs.channel).as_str(),
        "--expr",
        "toString <nixpkgs/programs.sqlite>",
    ]);

    command.enable_capture();
    command.log_to = LogTo::Log;
    command.log_output_on_error = true;

    let cow = command
        .run()
        .with_context(|| "Failed to gather information about nixpkgs programs")?;

    let output = &*cow.stdout_string_lossy();
    let programs_db: &str = serde_json::from_str(output)?;
    let conn = sqlite::open(programs_db)?;
    let cur = conn
        .prepare("SELECT name, package FROM Programs")?
        .into_iter();

    let mut programs: HashMap<String, HashSet<String>> = HashMap::new();
    for row in cur.map(|r| r.unwrap()) {
        let name: &str = row.read("name");
        let package: &str = row.read("package");
        programs
            .entry(package.into())
            .or_default()
            .insert(name.into());
    }

    Ok(programs)
}

pub fn get_nixpkgs_options(nixpkgs: &Source) -> Result<Vec<NixpkgsEntry>> {
    let mut command = Command::with_args("nix", &["eval", "--json"]);
    command.add_arg_pair("-f", super::EXTRACT_SCRIPT.clone());
    command.add_arg_pair("-I", format!("nixpkgs={}", nixpkgs.to_flake_ref()));
    command.add_arg("nixos-options");

    command.enable_capture();
    command.log_to = LogTo::Log;
    command.log_output_on_error = true;

    let cow = command
        .run()
        .with_context(|| "Failed to gather information about nixpkgs options")?;

    let output = &*cow.stdout_string_lossy();
    let de = &mut Deserializer::from_str(output);
    let attr_set: Vec<NixOption> =
        serde_path_to_error::deserialize(de).with_context(|| "Could not parse options")?;

    Ok(attr_set.into_iter().map(NixpkgsEntry::Option).collect())
}
