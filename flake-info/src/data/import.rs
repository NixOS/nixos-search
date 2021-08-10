use std::fmt::{self, write, Display};
use std::marker::PhantomData;
use std::{path::PathBuf, str::FromStr};

use serde::de::{self, MapAccess, Visitor};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;
use thiserror::Error;

use super::system::System;
use super::utility::{Flatten, OneOrMany};

/// Holds information about a specific derivation
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum FlakeEntry {
    /// A package as it may be defined in a flake
    ///
    /// Note: As flakes do not enforce any particular structure to be necessarily
    /// present, the data represented is an idealization that _should_ match in
    /// most cases and is open to extension.
    Package {
        attribute_name: String,
        name: String,
        version: String,
        platforms: Vec<System>,
        outputs: Vec<String>,
        description: Option<String>,
        #[serde(deserialize_with = "string_or_struct", default)]
        license: License,
    },
    /// An "application" that can be called using nix run <..>
    App {
        bin: Option<PathBuf>,
        attribute_name: String,
        platforms: Vec<System>,
        app_type: Option<String>,
    },
    /// an option defined in a module of a flake
    Option(NixOption),
}

/// The representation of an option that is part of some module and can be used
/// in some nixos configuration
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NixOption {
    /// Location of the defining module(s)
    pub declarations: Vec<String>,

    pub description: Option<String>,
    pub name: String,
    #[serde(rename = "type")]
    /// Nix generated description of the options type
    pub option_type: Option<String>,
    pub default: Option<Value>,
    pub example: Option<Value>,

    /// If defined in a flake, contains defining flake and module
    pub flake: Option<(String, String)>,
}

/// Package as defined in nixpkgs
/// These packages usually have a "more" homogenic structure that is given by
/// nixpkgs
/// note: This is the parsing module that deals with nested input. A flattened,
/// unified representation can be found in [crate::data::export::Derivation]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Package {
    pub pname: String,
    pub version: String,
    pub system: String,
    pub meta: Meta,
}

/// The nixpkgs output lists attribute names as keys of a map.
/// Name and Package definition are combined using this struct
#[derive(Debug, Clone)]
pub enum NixpkgsEntry {
    Derivation { attribute: String, package: Package },
    Option(NixOption),
}

/// Most information about packages in nixpkgs is contained in the meta key
/// This struct represents a subset of that metadata
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Meta {
    #[serde(rename = "outputsToInstall")]
    pub outputs: Option<Vec<String>>,
    pub license: Option<OneOrMany<StringOrStruct<License>>>,
    pub maintainers: Option<Flatten<Maintainer>>,
    pub homepage: Option<OneOrMany<String>>,
    pub platforms: Option<Flatten<System>>,
    pub position: Option<String>,
    pub description: Option<String>,
    #[serde(rename = "longDescription")]
    pub long_description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Maintainer {
    pub name: Option<String>,
    pub github: Option<String>,
    pub email: Option<String>,
}

/// The type of derivation (placed in packages.<system> or apps.<system>)
/// Used to command the extraction script
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

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct StringOrStruct<T>(pub T);

impl<'de, T> Deserialize<'de> for StringOrStruct<T>
where
    T: Deserialize<'de> + FromStr<Err = anyhow::Error>,
{
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        Ok(StringOrStruct(string_or_struct(deserializer)?))
    }
}

/// Different representations of the licence attribute
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
        // shortName: String,
        url: Option<String>,
    },
    Url {
        url: String,
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

/// Deserialization helper that parses an item using either serde or fromString
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

        let map: HashMap<String, Package> = serde_json::from_str(json).unwrap();

        let _: Vec<NixpkgsEntry> = map
            .into_iter()
            .map(|(attribute, package)| NixpkgsEntry::Derivation { attribute, package })
            .collect();
    }
}
