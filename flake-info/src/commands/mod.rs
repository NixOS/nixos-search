mod nix_check_version;
mod nix_flake_attrs;
mod nix_flake_info;
mod nixpkgs_info;
pub use nix_check_version::{check_nix_version, NixCheckError};
pub use nix_flake_attrs::get_derivation_info;
pub use nix_flake_info::get_flake_info;
pub use nixpkgs_info::{get_nixpkgs_info, get_nixpkgs_options};

use lazy_static::lazy_static;
use std::path::PathBuf;

lazy_static! {
    static ref EXTRACT_SCRIPT: PathBuf = crate::DATADIR.join("commands/flake_info.nix");
}
