#![recursion_limit = "256"]

use anyhow::Result;
use data::{import::Kind, Export, Flake, Source};
use lazy_static::lazy_static;
use std::path::{Path, PathBuf};

pub mod commands;
pub mod data;

#[cfg(feature = "elastic")]
pub mod elastic;

pub use commands::get_flake_info;
use log::trace;

lazy_static! {
    static ref DATADIR: PathBuf =
        Path::new(option_env!("ROOTDIR").unwrap_or(env!("CARGO_MANIFEST_DIR"))).join("assets");
}

pub fn process_flake(
    source: &Source,
    kind: &data::import::Kind,
    temp_store: bool,
    extra: &[String],
) -> Result<(Flake, Vec<Export>)> {
    let mut info = commands::get_flake_info(source.to_flake_ref(), temp_store, extra)?;
    info.source = Some(source.clone());
    let packages = commands::get_derivation_info(source.to_flake_ref(), *kind, temp_store, extra)?;
    trace!("flake info: {:#?}", info);
    trace!("flake content: {:#?}", packages);

    let exports: Vec<Export> = packages
        .into_iter()
        .map(|p| Export::flake(info.clone(), p))
        .collect::<Result<Vec<Export>>>()?;

    Ok((info, exports))
}

pub fn process_nixpkgs(nixpkgs: &Source, kind: &Kind) -> Result<Vec<Export>, anyhow::Error> {
    let drvs = if matches!(kind, Kind::All | Kind::Package) {
        commands::get_nixpkgs_info(nixpkgs)?
    } else {
        Vec::new()
    };

    let mut options = if matches!(kind, Kind::All | Kind::Option) {
        commands::get_nixpkgs_options(nixpkgs)?
    } else {
        Vec::new()
    };

    let mut all = drvs;
    all.append(&mut options);

    let exports = all
        .into_iter()
        .map(Export::nixpkgs)
        .collect::<Result<Vec<Export>>>()?;
    Ok(exports)
}
