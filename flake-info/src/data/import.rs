use std::fmt::{self, write, Display};
use std::marker::PhantomData;
use std::{path::PathBuf, str::FromStr};

use serde::de::{self, MapAccess, Visitor};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;
use thiserror::Error;

use super::system::System;

// TODO: Implement as typed object? -- Derivation<Kind>
/// Holds information about a specific derivation
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum FlakeEntry {
    Package {
        #[serde(rename(serialize = "package_attr_name"))]
        attribute_name: String,

        #[serde(rename(serialize = "package_pname"))]
        name: String,

        #[serde(rename(serialize = "package_pversion"))]
        version: String,

        #[serde(rename(serialize = "package_platforms"))]
        platforms: Vec<System>,

        #[serde(rename(serialize = "package_outputs"))]
        outputs: Vec<String>,

        #[serde(
            rename(serialize = "package_description"),
            skip_serializing_if = "Option::is_none"
        )]
        description: Option<String>,

        #[serde(
            rename(serialize = "package_license"),
            deserialize_with = "string_or_struct",
            default
        )]
        license: License,
    },
    App {
        #[serde(rename(serialize = "app_bin"), skip_serializing_if = "Option::is_none")]
        bin: Option<PathBuf>,
        #[serde(rename(serialize = "app_attr_name"))]
        attribute_name: String,
        #[serde(rename(serialize = "app_platforms"))]
        platforms: Vec<System>,
        #[serde(rename(deserialize = "type"), skip_serializing_if = "Option::is_none")]
        app_type: Option<String>,
    },
    Option {
        #[serde(rename(serialize = "option_source"))]
        declarations: Vec<String>,
        #[serde(
            rename(serialize = "option_description"),
            skip_serializing_if = "Option::is_none"
        )]
        description: Option<String>,
        #[serde(rename(serialize = "option_name"))]
        name: String,
        #[serde(
            rename(deserialize = "type", serialize = "option_type"),
            skip_serializing_if = "Option::is_none"
        )]
        option_type: Option<String>,
        #[serde(
            rename(serialize = "option_default"),
            skip_serializing_if = "Option::is_none"
        )]
        default: Option<Value>,
        #[serde(
            rename(serialize = "option_example"),
            skip_serializing_if = "Option::is_none"
        )]
        example: Option<Value>,
        #[serde(
            rename(serialize = "option_flake"),
            skip_serializing_if = "Option::is_none"
        )]
        flake: Option<(String, String)>,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Package {
    pub pname: String,
    pub version: String,
    pub meta: Meta,
}

pub struct NixpkgsEntry{
    pub attribute: String,
    pub package: Package
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Meta {
    #[serde(rename = "outputsToInstall")]
    pub outputs: Vec<String>,
    pub licenses: Option<OneOrMany<License>>,
    pub maintainer: Option<OneOrMany<String>>,
    pub homepage: Option<String>,
    pub platforms: Vec<System>,
    pub position: Option<String>,
    pub description: Option<String>,
    pub long_description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum OneOrMany<T> {
    #[serde(serialize_with = "list")]
    One(T),
    Many(Vec<T>),
}

pub fn list<T, S>(item: &T, s: S) -> Result<S::Ok, S::Error>
where
    T: Serialize,
    S: Serializer,
{
    s.collect_seq(vec![item].iter())
}

/// The type of derivation (placed in packages.<system> or apps.<system>)
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub enum Kind {
    App,
    Package,
    Option,
    All,
}

impl AsRef<str> for Kind {
    fn as_ref(&self) -> &str {
        match self {
            Kind::App => "app",
            Kind::Package => "packages",
            Kind::Option => "options",
            Kind::All => "all",
        }
    }
}

impl Display for Kind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.as_ref())
    }
}

#[derive(Debug, Error)]
pub enum ParseKindError {
    #[error("Failed to parse kind: {0}")]
    UnknownKind(String),
}

impl FromStr for Kind {
    type Err = ParseKindError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let kind = match s {
            "app" => Kind::App,
            "packages" => Kind::Package,
            "options" => Kind::Option,
            "all" => Kind::All,
            _ => return Err(ParseKindError::UnknownKind(s.into())),
        };
        Ok(kind)
    }
}

impl Default for Kind {
    fn default() -> Self {
        Kind::All
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum License {
    None {
        #[serde(skip_serializing)]
        license: (),
    },
    Simple {
        license: String,
    },
    Full {
        fullName: String,
        shortName: String,
        url: Option<String>,
    },
}

impl Default for License {
    fn default() -> Self {
        License::None { license: () }
    }
}

impl FromStr for License {
    // This implementation of `from_str` can never fail, so use the impossible
    // `Void` type as the error type.
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(License::Simple {
            license: s.to_string(),
        })
    }
}

fn string_or_struct<'de, T, D>(deserializer: D) -> Result<T, D::Error>
where
    T: Deserialize<'de> + FromStr<Err = anyhow::Error>,
    D: Deserializer<'de>,
{
    // This is a Visitor that forwards string types to T's `FromStr` impl and
    // forwards map types to T's `Deserialize` impl. The `PhantomData` is to
    // keep the compiler from complaining about T being an unused generic type
    // parameter. We need T in order to know the Value type for the Visitor
    // impl.
    struct StringOrStruct<T>(PhantomData<fn() -> T>);

    impl<'de, T> Visitor<'de> for StringOrStruct<T>
    where
        T: Deserialize<'de> + FromStr<Err = anyhow::Error>,
    {
        type Value = T;

        fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
            formatter.write_str("string or map")
        }

        fn visit_str<E>(self, value: &str) -> Result<T, E>
        where
            E: de::Error,
        {
            Ok(FromStr::from_str(value).unwrap())
        }

        fn visit_map<M>(self, map: M) -> Result<T, M::Error>
        where
            M: MapAccess<'de>,
        {
            // `MapAccessDeserializer` is a wrapper that turns a `MapAccess`
            // into a `Deserializer`, allowing it to be used as the input to T's
            // `Deserialize` implementation. T then deserializes itself using
            // the entries from the map visitor.
            Deserialize::deserialize(de::value::MapAccessDeserializer::new(map))
        }
    }

    deserializer.deserialize_any(StringOrStruct(PhantomData))
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use serde_json::Value;

    use super::*;

    #[test]
    fn test_nixpkgs_deserialize() {
        let json = r#"
        {
            "nixpkgs-unstable._0verkill": {
              "name": "0verkill-unstable-2011-01-13",
              "pname": "0verkill-unstable",
              "version": "2011-01-13",
              "system": "x86_64-darwin",
              "meta": {
                "available": true,
                "broken": false,
                "description": "ASCII-ART bloody 2D action deathmatch-like game",
                "homepage": "https://github.com/hackndev/0verkill",
                "insecure": false,
                "license": {
                  "fullName": "GNU General Public License v2.0 only",
                  "shortName": "gpl2Only",
                  "spdxId": "GPL-2.0-only",
                  "url": "https://spdx.org/licenses/GPL-2.0-only.html"
                },
                "maintainers": [
                  {
                    "email": "torres.anderson.85@protonmail.com",
                    "github": "AndersonTorres",
                    "githubId": 5954806,
                    "name": "Anderson Torres"
                  }
                ],
                "name": "0verkill-unstable-2011-01-13",
                "outputsToInstall": [
                  "out"
                ],
                "platforms": [
                  "powerpc64-linux",
                  "powerpc64le-linux",
                  "riscv32-linux",
                  "riscv64-linux"
                ],
                "position": "/nix/store/97lxf2n6zip41j5flbv6b0928mxv9za8-nixpkgs-unstable-21.03pre268853.d9c6f13e13f/nixpkgs-unstable/pkgs/games/0verkill/default.nix:34",
                "unfree": false,
                "unsupported": false
              }
            }
        }
        "#;

        let  map: HashMap<String, Package> = serde_json::from_str(json).unwrap();

        map.into_iter().map(|(attribute, package)| NixpkgsEntry {attribute, package});
    }
}
