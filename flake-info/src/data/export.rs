use serde::Serialize;

use super::{Derivation, Flake};

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Export {
    #[serde(flatten)]
    pub flake: Flake,

    #[serde(flatten)]
    pub item: Derivation,
}
