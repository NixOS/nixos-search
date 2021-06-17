use std::path::PathBuf;

use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;
use tokio::macros::support;

use crate::data::import::NixOption;

use super::{
    import,
    system::System,
    utility::{AttributeQuery, Flatten, OneOrMany, Reverse},
};

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
            import::License::Url { url } => License {
                url: Some(url),
                fullName: "No Name".into(),
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum Derivation {
    #[serde(rename = "package")]
    Package {
        package_attr_name: String,
        package_attr_name_reverse: Reverse<String>,
        package_attr_name_query: AttributeQuery,
        package_attr_name_query_reverse: Reverse<AttributeQuery>,
        package_attr_set: String,
        package_attr_set_reverse: Reverse<String>,
        package_pname: String,
        package_pname_reverse: Reverse<String>,
        package_pversion: String,
        package_platforms: Vec<System>,
        package_outputs: Vec<String>,
        package_license: Vec<License>,
        package_license_set: Vec<String>,
        package_maintainers: Vec<Maintainer>,
        package_maintainers_set: Vec<String>,
        package_description: Option<String>,
        package_description_reverse: Option<Reverse<String>>,
        package_longDescription: Option<String>,
        package_longDescription_reverse: Option<Reverse<String>>,
        package_hydra: (),
        package_system: String,
        package_homepage: Vec<String>,
        package_position: Option<String>,
    },
    #[serde(rename = "app")]
    App {
        app_attr_name: String,
        app_platforms: Vec<System>,

        app_type: Option<String>,

        app_bin: Option<PathBuf>,
    },
    #[serde(rename = "option")]
    Option {
        option_source: Option<String>,
        option_name: String,
        option_name_reverse: Reverse<String>,

        option_description: Option<String>,
        option_description_reverse: Option<Reverse<String>>,

        option_type: Option<String>,

        option_default: Option<String>,

        option_example: Option<String>,

        option_flake: Option<(String, String)>,
    },
}

impl From<(import::FlakeEntry, super::Flake)> for Derivation {
    fn from((d, f): (import::FlakeEntry, super::Flake)) -> Self {
        match d {
            import::FlakeEntry::Package {
                attribute_name,
                name,
                version,
                platforms,
                outputs,
                description,
                license,
            } => {
                let package_attr_set: Vec<_> = attribute_name.split(".").collect();
                let package_attr_set: String = (if package_attr_set.len() > 1 {
                    package_attr_set[0]
                } else {
                    "No package set"
                })
                .into();

                let package_attr_set_reverse = Reverse(package_attr_set.clone());

                let package_license: Vec<License> = vec![license.into()];
                let package_license_set: Vec<String> = package_license
                    .iter()
                    .clone()
                    .map(|l| l.fullName.to_owned())
                    .collect();

                let maintainer: Maintainer = f.into();

                Derivation::Package {
                    package_attr_name_query: AttributeQuery::new(&attribute_name),
                    package_attr_name_query_reverse: Reverse(AttributeQuery::new(&attribute_name)),
                    package_attr_name: attribute_name.clone(),
                    package_attr_name_reverse: Reverse(attribute_name),
                    package_attr_set,
                    package_attr_set_reverse,
                    package_pname: name.clone(),
                    package_pname_reverse: Reverse(name),
                    package_pversion: version,
                    package_platforms: platforms,
                    package_outputs: outputs,
                    package_license,
                    package_license_set,
                    package_description: description.clone(),
                    package_maintainers: vec![maintainer.clone()],
                    package_maintainers_set: maintainer.name.map_or(vec![], |n| vec![n]),
                    package_description_reverse: description.map(Reverse),
                    package_longDescription: None,
                    package_longDescription_reverse: None,
                    package_hydra: (),
                    package_system: String::new(),
                    package_homepage: Vec::new(),
                    package_position: None,
                }
            }
            import::FlakeEntry::App {
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
            import::FlakeEntry::Option(NixOption {
                declarations,
                description,
                name,
                option_type,
                default,
                example,
                flake,
            }) => Derivation::Option {
                option_source: declarations.get(0).map(Clone::clone),
                option_name: name.clone(),
                option_description: description.clone(),
                option_default: default.map(|v| v.to_string()),
                option_example: example.map(|v| v.to_string()),
                option_flake: flake,
                option_type,
                option_name_reverse: Reverse(name),
                option_description_reverse: description.map(Reverse),
            },
        }
    }
}

impl From<import::NixpkgsEntry> for Derivation {
    fn from(entry: import::NixpkgsEntry) -> Self {
        let package_attr_set: Vec<_> = entry.attribute.split(".").collect();
        let package_attr_set: String = (if package_attr_set.len() > 1 {
            package_attr_set[0]
        } else {
            "No package set"
        })
        .into();

        let package_attr_set_reverse = Reverse(package_attr_set.clone());

        let package_license: Vec<_> = entry
            .package
            .meta
            .license
            .map(OneOrMany::into_list)
            .unwrap_or_default()
            .into_iter()
            .map(|sos| sos.0.into())
            .collect();

        let package_license_set = package_license
            .iter()
            .map(|l: &License| l.fullName.to_owned())
            .collect();

        let package_maintainers = entry
            .package
            .meta
            .maintainers
            .map_or(Default::default(), Flatten::flatten);

        let package_maintainers_set = package_maintainers
            .iter()
            .filter(|m| m.name.is_some())
            .map(|m| m.name.to_owned().unwrap())
            .collect();

        Derivation::Package {
            package_attr_name: entry.attribute.clone(),
            package_attr_name_reverse: Reverse(entry.attribute.clone()),
            package_attr_name_query: AttributeQuery::new(&entry.attribute),
            package_attr_name_query_reverse: Reverse(AttributeQuery::new(&entry.attribute)),
            package_attr_set,
            package_attr_set_reverse,
            package_pname: entry.package.pname.clone(),
            package_pname_reverse: Reverse(entry.package.pname),
            package_pversion: entry.package.version,
            package_platforms: entry
                .package
                .meta
                .platforms
                .map(Flatten::flatten)
                .unwrap_or_default(),
            package_outputs: entry.package.meta.outputs.unwrap_or_default(),
            package_license,
            package_license_set,
            package_maintainers,
            package_maintainers_set,
            package_description: entry.package.meta.description.clone(),
            package_description_reverse: entry.package.meta.description.map(Reverse),
            package_longDescription: entry.package.meta.long_description.clone(),
            package_longDescription_reverse: entry.package.meta.long_description.map(Reverse),
            package_hydra: (),
            package_system: entry.package.system,
            package_homepage: entry
                .package
                .meta
                .homepage
                .map_or(Default::default(), OneOrMany::into_list),
            package_position: entry.package.meta.position,
        }
    }
}

type Maintainer = import::Maintainer;

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
            github: Some(github),
            email: None,
            name: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Export {
    #[serde(flatten)]
    flake: Option<Flake>,

    #[serde(flatten)]
    item: Derivation,
}

impl Export {
    pub fn flake(flake: Flake, item: import::FlakeEntry) -> Self {
        Self {
            flake: Some(flake.clone()),
            item: Derivation::from((item, flake)),
        }
    }

    pub fn nixpkgs(item: import::NixpkgsEntry) -> Self {
        Self {
            flake: None,
            item: Derivation::from(item),
        }
    }
}
