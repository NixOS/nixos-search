use serde::Serialize;

use super::{Derivation, Flake};

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Export {
    Flake {
        #[serde(flatten)]
        flake: Flake,

        #[serde(flatten)]
        item: Derivation,
    },
    Nixpkgs(Derivation)
}
