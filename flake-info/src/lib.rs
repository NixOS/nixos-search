use std::path::PathBuf;

use anyhow::Result;
use data::{Export, Source};

pub mod commands;
pub mod data;
pub mod elastic;


pub fn process_flake(source: &Source, kind: &data::Kind, temp_store: bool, extra: &[String]) -> Result<Vec<Export>> {
    let mut info = commands::get_flake_info(source.to_flake_ref(), temp_store, &extra)?;
    info.source = Some(source.clone());
    let packages = commands::get_derivation_info(source.to_flake_ref(), *kind, temp_store, &extra)?;
    eprintln!("{:#?}", info);
    eprintln!("{:#?}", packages);

    let exports: Vec<Export> = packages
        .into_iter()
        .map(|p| Export::Flake {
            flake: info.clone(),
            item: p,
        })
        .collect();

    Ok(exports)
}

pub fn process_nixpkgs(nixpkgs: &Source) -> Result<Vec<Export>, anyhow::Error> {
    let drvs = commands::get_nixpkgs_info(nixpkgs.to_flake_ref())?;
    let exports = drvs.into_iter().map(Export::Nixpkgs).collect();
    Ok(exports)
}
