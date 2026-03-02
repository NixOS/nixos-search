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
use log::{trace, warn};

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
    let fetch =
        |kind| commands::get_derivation_info(source.to_flake_ref(), kind, temp_store, extra);
    let packages = match fetch(*kind) {
        Ok(packages) => packages,
        Err(err) => {
            if matches!(kind, Kind::All) {
                warn!(
                    "Failed to extract options for {} ({}). Retrying with packages+apps only.",
                    source.to_flake_ref(),
                    err
                );
                let packages_result = fetch(Kind::Package);
                let apps_result = fetch(Kind::App);
                match (packages_result, apps_result) {
                    (Ok(mut packages), Ok(mut apps)) => {
                        packages.append(&mut apps);
                        packages
                    }
                    (Ok(packages), Err(apps_err)) => {
                        warn!(
                            "Failed to extract apps for {} ({}). Continuing with packages only.",
                            source.to_flake_ref(),
                            apps_err
                        );
                        packages
                    }
                    (Err(packages_err), Ok(apps)) => {
                        warn!(
                            "Failed to extract packages for {} ({}). Continuing with apps only.",
                            source.to_flake_ref(),
                            packages_err
                        );
                        apps
                    }
                    (Err(packages_err), Err(_apps_err)) => {
                        return Err(packages_err);
                    }
                }
            } else {
                return Err(err);
            }
        }
    };

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
) -> Result<Vec<Export>, anyhow::Error> {
    let drvs = if matches!(kind, Kind::All | Kind::Package) {
        commands::get_nixpkgs_info(nixpkgs, attribute)?
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
