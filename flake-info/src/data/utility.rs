use fancy_regex::Regex;
use lazy_static::lazy_static;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

#[derive(Debug, Clone, PartialEq)]
pub struct Reverse<T: Reversable + Serialize>(pub T);

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

    pub fn query(&self) -> &[String] {
        &self.0
    }
}

impl Reversable for AttributeQuery {
    fn reverse(&self) -> Self {
        AttributeQuery(self.query().to_owned().reverse())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn attr_query_test() {
        assert_eq!(
            {
                let mut q = AttributeQuery::new("services.nginx.extraConfig")
                    .query()
                    .to_owned();
                q.sort();
                q
            },
            {
                let mut ex = [
                    "services.nginx.extraConfig",
                    "services.nginx.extra",
                    "services.nginx",
                    "services",
                    "nginx.extraConfig",
                    "nginx.extra",
                    "nginx",
                    "extraConfig",
                    "extra",
                    "Config",
                ];
                ex.sort_unstable();
                ex
            },
        );

        assert_eq!(
            {
                let mut q = AttributeQuery::new("python37Packages.test1_name-test2")
                    .query()
                    .to_owned();
                q.sort();
                q
            },
            {
                let mut ex = [
                    "python37Packages.test1_name-test2",
                    "python37Packages.test1_name-test",
                    "python37Packages.test1_name",
                    "python37Packages.test1",
                    "python37Packages.test",
                    "python37Packages",
                    "python37",
                    "python",
                    "37Packages.test1_name-test2",
                    "37Packages.test1_name-test",
                    "37Packages.test1_name",
                    "37Packages.test1",
                    "37Packages.test",
                    "37Packages",
                    "37",
                    "Packages.test1_name-test2",
                    "Packages.test1_name-test",
                    "Packages.test1_name",
                    "Packages.test1",
                    "Packages.test",
                    "Packages",
                    "test1_name-test2",
                    "test1_name-test",
                    "test1_name",
                    "test1",
                    "test",
                    "1_name-test2",
                    "1_name-test",
                    "1_name",
                    "1",
                    "name-test2",
                    "name-test",
                    "name",
                    "test2",
                    "test",
                    "2",
                ];
                ex.sort_unstable();
                ex
            }
        );
    }
}
