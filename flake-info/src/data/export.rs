use std::path::PathBuf;

use serde::{Deserialize, Deserializer, Serialize};
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
#[serde(tag="type")]
pub enum Derivation {
    Package {
        package_attr_name: String,
        package_attr_name_reverse: Reverse<String>,
        package_pname: String,
        package_pname_reverse: Reverse<String>,
        package_pversion: String,
        package_platforms: Vec<System>,
        package_outputs: Vec<String>,
        package_licenses: Vec<License>,
        package_maintainers: Vec<Maintainer>,

        package_description: Option<String>,
        package_description_reverse: Option<Reverse<String>>,

        // #[serde(skip_serializing_if = "Option::is_none")]
        package_longDescription: Option<String>,
        package_longDescription_reverse: Option<Reverse<String>>,
    },
    App {
        app_attr_name: String,
        app_platforms: Vec<System>,

        app_type: Option<String>,

        app_bin: Option<PathBuf>,
    },
    Option {
        option_source: Vec<String>,
        option_name: String,
        option_name_reverse: Reverse<String>,

        option_description: Option<String>,
        option_description_reverse: Option<Reverse<String>>,

        option_type: Option<String>,

        option_default: Option<Value>,

        option_example: Option<Value>,

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
            } => Derivation::Package {
                package_attr_name: attribute_name.clone(),
                package_pname: name.clone(),
                package_pversion: version,
                package_platforms: platforms,
                package_outputs: outputs,
                package_licenses: vec![license.into()],
                package_description: description.clone(),
                package_maintainers: vec![f.into()],
                package_attr_name_reverse: Reverse(attribute_name),
                package_pname_reverse: Reverse(name),
                package_description_reverse: description.map(Reverse),
                package_longDescription: None,
                package_longDescription_reverse: None,
            },
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
                option_default: default,
                option_example: example,
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
        Derivation::Package {
            package_attr_name: entry.attribute.clone(),
            package_pname: entry.package.pname.clone(),
            package_pversion: entry.package.version,
            package_platforms: entry.package.meta.platforms,
            package_outputs: entry.package.meta.outputs,
            package_licenses: vec![],
            package_maintainers: vec![],
            package_description: entry.package.meta.description.clone(),
            package_attr_name_reverse: Reverse(entry.attribute),
            package_pname_reverse: Reverse(entry.package.pname),
            package_description_reverse: entry.package.meta.description.map(Reverse),
            package_longDescription: entry.package.meta.long_description.clone(),
            package_longDescription_reverse: entry.package.meta.long_description.map(Reverse),
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
    flake: Option<Flake>,

    #[serde(flatten)]
    item: Derivation,
}

impl Export {
    pub fn flake(flake: Flake, item: import::FlakeEntry) -> Self {
        Self {
            flake: Some(flake.clone()),
            item: Derivation::from((item, flake))
        }
    }

    pub fn nixpkgs(item: import::NixpkgsEntry) -> Self {
        Self {
            flake: None,
            item: Derivation::from(item),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Reverse<T: Reversable + Serialize>(T);

pub trait Reversable {
    fn reverse(&self) -> Self;
}

impl Reversable for String {
    fn reverse(&self) -> Self {
        self.chars().rev().collect::<String>()
    }
}

impl<T: Reversable + Clone> Reversable for Vec<T> {
    fn reverse(&self) -> Self {
        self.iter().cloned().map(|item| item.reverse()).collect()
    }
}

impl<T> Reversable for Reverse<T>
where
    T: Reversable + Serialize,
{
    fn reverse(&self) -> Self {
        Reverse(self.0.reverse())
    }
}

impl<T> Serialize for Reverse<T>
where
    T: Reversable + Serialize,
{
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        self.0.reverse().serialize(serializer)
    }
}

impl<'de, T> Deserialize<'de> for Reverse<T>
where
    T: Reversable + Serialize + Deserialize<'de>,
{
    fn deserialize<D>(deserializer: D) -> Result<Reverse<T>, D::Error>
    where
        D: Deserializer<'de>,
    {
        Ok(Reverse(T::deserialize(deserializer)?.reverse()))
    }
}
