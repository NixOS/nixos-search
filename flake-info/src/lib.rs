#![recursion_limit = "256"]

use std::path::PathBuf;

use anyhow::Result;
use data::{import::Kind, Export, Source};

pub mod commands;
pub mod data;
pub mod elastic;

pub use commands::get_flake_info;

pub fn process_flake(
    source: &Source,
    kind: &data::import::Kind,
    temp_store: bool,
    extra: &[String],
) -> Result<Vec<Export>> {
    let mut info = commands::get_flake_info(source.to_flake_ref(), temp_store, extra)?;
    info.source = Some(source.clone());
    let packages = commands::get_derivation_info(source.to_flake_ref(), *kind, temp_store, extra)?;
    eprintln!("{:#?}", info);
    eprintln!("{:#?}", packages);

    let exports: Vec<Export> = packages
        .into_iter()
        .map(|p| Export::flake(info.clone(), p))
        .collect();

    Ok(exports)
}

pub fn process_nixpkgs(nixpkgs: &Source, kind: &Kind) -> Result<Vec<Export>, anyhow::Error> {
    let drvs = if matches!(kind, Kind::All | Kind::Package) {
        commands::get_nixpkgs_info(nixpkgs.to_flake_ref())?
    } else {
        Vec::new()
    };

    let mut options = if matches!(kind, Kind::All | Kind::Option) {
        commands::get_nixpkgs_options(nixpkgs.to_flake_ref())?
    } else {
        Vec::new()
    };

    let mut all = drvs;
    all.append(&mut options);

    let exports = all.into_iter().map(Export::nixpkgs).collect();
    Ok(exports)
}
