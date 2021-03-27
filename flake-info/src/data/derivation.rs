use std::fmt::{self, write, Display};
use std::marker::PhantomData;
use std::{path::PathBuf, str::FromStr};

use serde::de::{self, MapAccess, Visitor};
use serde::{Deserialize, Deserializer, Serialize};
use thiserror::Error;

use super::system::System;

// TODO: Implement as typed object? -- Derivation<Kind>
/// Holds information about a specific derivation
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Derivation {
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
        license: ()
    },
    Simple {
        license: String,
    },
    Full {
        #[serde(rename(serialize = "license_long"))]
        fullName: String,
        #[serde(rename(serialize = "license"))]
        shortName: String,
        #[serde(rename(serialize = "license_url"))]
        url: Option<String>,
    },
}

impl Default for License {
    fn default() -> Self {
        License::None {license: ( )}
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

// fn optional_string_or_struct<'de, T, D>(deserializer: D) -> Result<Option<T>, D::Error>
// where
//     T: Deserialize<'de> + FromStr<Err = anyhow::Error>,
//     D: Deserializer<'de>,
// {
//     string_or_struct(deserializer).map(Some).map_err(Some(None))
// }
