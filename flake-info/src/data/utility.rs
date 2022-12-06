use fancy_regex::Regex;
use lazy_static::lazy_static;
use serde::{Deserialize, Serialize, Serializer};

/// A utility type that can represent the presence of either a single associated
/// value or a list of those. Adding absence can be achieved by wrapping the type
/// in an [Option]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum OneOrMany<T> {
    #[serde(serialize_with = "list")]
    One(T),
    Many(Vec<T>),
}

impl<T> OneOrMany<T> {
    pub fn into_list(self) -> Vec<T> {
        match self {
            OneOrMany::One(one) => vec![one],
            OneOrMany::Many(many) => many,
        }
    }
}

/// A utility type that flattens lists of lists as seen with `maintainers` and `platforms` on selected packages
/// in an [Option]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Flatten<T> {
    #[serde(serialize_with = "list")]
    Single(T),
    Deep(Vec<Flatten<T>>),
}

impl<T: Clone> Flatten<T> {
    pub fn flatten(self) -> Vec<T> {
        match self {
            Flatten::Single(s) => vec![s],
            Flatten::Deep(v) => v.into_iter().map(Flatten::flatten).flatten().collect(),
        }
    }
}

// TODO: use this or a to_ist function?
/// Serialization helper that serializes single elements as a list with a single
/// item
pub fn list<T, S>(item: &T, s: S) -> Result<S::Ok, S::Error>
where
    T: Serialize,
    S: Serializer,
{
    s.collect_seq(vec![item].iter())
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AttributeQuery(Vec<String>);

lazy_static! {
    static ref QUERY: Regex =
        Regex::new(".+?(?:(?<=[a-z])(?=[1-9A-Z])|(?<=[1-9A-Z])(?=[A-Z][a-z])|[._-]|$)").unwrap();
}

impl AttributeQuery {
    pub fn new(attribute_name: &str) -> Self {
        const SUFFIX: &[char] = &['-', '.', '_'];

        let matches = QUERY
            .find_iter(attribute_name)
            .map(|found| found.unwrap().as_str())
            .collect::<Vec<_>>();

        let tokens = (0..matches.len())
            .flat_map(|index| {
                let (_, tokens) = matches.iter().skip(index).fold(
                    (String::new(), Vec::new()),
                    |(prev_parts, mut tokens), part| {
                        let token: String = prev_parts + part;
                        tokens.push(token.trim_end_matches(SUFFIX).to_owned());
                        (token, tokens)
                    },
                );

                tokens
            })
            .collect::<Vec<_>>();

        AttributeQuery(tokens)
    }
}
