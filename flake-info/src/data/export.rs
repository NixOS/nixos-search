use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::macros::support;

use super::{import, system::System};

type Flake = super::Flake;

#[allow(non_snake_case)]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct License {
    url: Option<String>,
    fullName: String,
}

impl From<import::License> for License {
    #[allow(non_snake_case)]
    fn from(license: import::License) -> Self {
        match license {
            import::License::None { .. } => License {
                url: None,
                fullName: "No License Specified".to_string(),
            },
            import::License::Simple { license } => License {
                url: None,
                fullName: license,
            },
            import::License::Full { fullName, url, .. } => License { url, fullName },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Derivation {
    Package {
        package_attr_name: String,
        package_pname: String,
        package_pversion: String,
        package_platforms: Vec<System>,
        package_outputs: Vec<String>,
        package_licenses: Vec<License>,
        package_maintainers: Vec<Maintainer>,

        #[serde(skip_serializing_if = "Option::is_none")]
        package_description: Option<String>,
    },
    App {
        app_attr_name: String,
        app_platforms: Vec<System>,

        #[serde(skip_serializing_if = "Option::is_none")]
        app_type: Option<String>,

        #[serde(skip_serializing_if = "Option::is_none")]
        app_bin: Option<PathBuf>,
    },
    Option {
        option_source: Vec<String>,
        option_name: String,

        #[serde(skip_serializing_if = "Option::is_none")]
        option_description: Option<String>,

        #[serde(skip_serializing_if = "Option::is_none")]
        option_type: Option<String>,

        #[serde(skip_serializing_if = "Option::is_none")]
        option_default: Option<Value>,

        #[serde(skip_serializing_if = "Option::is_none")]
        option_example: Option<Value>,

        #[serde(skip_serializing_if = "Option::is_none")]
        option_flake: Option<(String, String)>,
    },
}

impl From<(import::Derivation, super::Flake)> for Derivation {
    fn from((d, f): (import::Derivation, super::Flake)) -> Self {
        match d {
            import::Derivation::Package {
                attribute_name,
                name,
                version,
                platforms,
                outputs,
                description,
                license,
            } => Derivation::Package {
                package_attr_name: attribute_name,
                package_pname: name,
                package_pversion: version,
                package_platforms: platforms,
                package_outputs: outputs,
                package_licenses: vec![license.into()],
                package_description: description,
                package_maintainers: vec![f.into()],
            },
            import::Derivation::App {
                bin,
                attribute_name,
                platforms,
                app_type,
            } => Derivation::App {
                app_attr_name: attribute_name,
                app_platforms: platforms,
                app_bin: bin,
                app_type,
            },
            import::Derivation::Option {
                declarations,
                description,
                name,
                option_type,
                default,
                example,
                flake,
            } => Derivation::Option {
                option_source: declarations,
                option_name: name,
                option_description: description,
                option_default: default,
                option_example: example,
                option_flake: flake,
                option_type,
            }
        }
    }
}

impl From<import::Nixpkgs> for Derivation {
    fn from(n: import::Nixpkgs) -> Self {
        Derivation::Package {
            package_attr_name: n.attribute_name,
            package_pname: n.pname,
            package_pversion: n.version,
            package_platforms: n.meta.platforms,
            package_outputs: n.meta.outputs,
            package_licenses: vec![],
            package_maintainers: vec![],
            package_description: n.meta.description,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Maintainer {
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    github: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    email: Option<String>,
}

impl From<super::Flake> for Maintainer {
    fn from(flake: super::Flake) -> Self {
        let github = flake
            .source
            .and_then(|source| match source {
                super::Source::Github { owner, .. } => Some(owner),
                _ => None,
            })
            .unwrap_or_else(|| "Maintainer Unknown".to_string());

        Maintainer {
            github,
            email: None,
            name: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Export {
    #[serde(flatten)]
    pub flake: Option<Flake>,

    #[serde(flatten)]
    pub item: Derivation,
}

impl Export {
    pub fn flake(flake: Flake, item: import::Derivation) -> Self {
        Self {
            flake: Some(flake.clone()),
            item: Derivation::from((item, flake))
        }
    }

    pub fn nixpkgs(item: import::Nixpkgs) -> Self {
        Self {
            flake: None,
            item: Derivation::from(item),
        }
    }
}
