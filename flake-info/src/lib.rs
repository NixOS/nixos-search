#![recursion_limit = "256"]

use anyhow::Result;
use data::{Export, Flake, Source, import::Kind};
use lazy_static::lazy_static;
use std::path::{Path, PathBuf};

pub mod commands;
pub mod data;

#[cfg(feature = "elastic")]
pub mod elastic;

pub use commands::get_flake_info;
use log::{info, trace};

lazy_static! {
    static ref DATADIR: PathBuf =
        Path::new(option_env!("ROOTDIR").unwrap_or(env!("CARGO_MANIFEST_DIR"))).join("assets");
}

pub fn process_flake(
    source: &Source,
    kind: &data::import::Kind,
    temp_store: bool,
    extra: &[String],
    with_gc: bool,
) -> Result<(Flake, Vec<Export>)> {
    let mut info = commands::get_flake_info(source.to_flake_ref(), temp_store, extra)?;
    info.source = Some(source.clone());
    info!(
        "Resolved {} to revision {}",
        source.to_flake_ref(),
        info.revision.as_deref().unwrap_or("(unknown)"),
    );
    let packages = commands::get_derivation_info(source.to_flake_ref(), *kind, temp_store, extra)?;

    if with_gc {
        commands::run_garbage_collection()?;
    }

    trace!("flake info: {:#?}", info);
    trace!("flake content: {:#?}", packages);

    let exports: Vec<Export> = packages
        .into_iter()
        .map(|p| Export::flake(info.clone(), p))
        .collect::<Result<Vec<Export>>>()?;

    Ok((info, exports))
}

pub fn process_nixpkgs(
    nixpkgs: &Source,
    kind: &Kind,
    attribute: &Option<String>,
    packages_json_url: &Option<String>,
    options_json_url: &Option<String>,
    repology_counts_file: &Option<PathBuf>,
) -> Result<Vec<Export>, anyhow::Error> {
    let drvs = if matches!(kind, Kind::All | Kind::Package) {
        commands::get_nixpkgs_info(nixpkgs, attribute, packages_json_url, repology_counts_file)?
    } else {
        Vec::new()
    };

    let mut options = if matches!(kind, Kind::All | Kind::Option) {
        commands::get_nixpkgs_options(nixpkgs, options_json_url)?
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
