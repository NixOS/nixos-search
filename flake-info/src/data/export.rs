/// This module defines the unified putput format as expected by the elastic search
/// Additionally, we implement converseions from the two possible input formats, i.e.
/// Flakes, or Nixpkgs.
use std::path::PathBuf;

use crate::data::import::NixOption;
use pandoc::{InputFormat, InputKind, OutputFormat, OutputKind, PandocOption, PandocOutput};
use serde::{Deserialize, Serialize};

use super::{
    import,
    prettyprint::print_value,
    system::System,
    utility::{AttributeQuery, Flatten, OneOrMany, Reverse},
};
use lazy_static::lazy_static;

lazy_static! {
    static ref FILTERS_PATH: PathBuf = std::env::var("NIXPKGS_PANDOC_FILTERS_PATH")
        .unwrap_or("".into())
        .into();
}

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

// ----- Unified derivation representation

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
        option_name_query: AttributeQuery,
        option_name_query_reverse: Reverse<AttributeQuery>,

        option_description: Option<String>,
        option_description_reverse: Option<Reverse<String>>,

        option_type: Option<String>,

        option_default: Option<String>,

        option_example: Option<String>,

        option_flake: Option<(String, String)>,
    },
}

// ----- Conversions

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
            import::FlakeEntry::Option(option) => option.into(),
        }
    }
}

impl From<import::NixpkgsEntry> for Derivation {
    fn from(entry: import::NixpkgsEntry) -> Self {
        match entry {
            import::NixpkgsEntry::Derivation { attribute, package } => {
                let package_attr_set: Vec<_> = attribute.split(".").collect();
                let package_attr_set: String = (if package_attr_set.len() > 1 {
                    package_attr_set[0]
                } else {
                    "No package set"
                })
                .into();

                let package_attr_set_reverse = Reverse(package_attr_set.clone());

                let package_license: Vec<_> = package
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

                let package_maintainers = package
                    .meta
                    .maintainers
                    .map_or(Default::default(), Flatten::flatten);

                let package_maintainers_set = package_maintainers
                    .iter()
                    .filter(|m| m.name.is_some())
                    .map(|m| m.name.to_owned().unwrap())
                    .collect();

                let position: Option<String> = package.meta.position.map(|p| {
                    if p.starts_with("/nix/store") {
                        p.split("/").skip(4).collect::<Vec<&str>>().join("/")
                    } else {
                        p
                    }
                });

                Derivation::Package {
                    package_attr_name: attribute.clone(),
                    package_attr_name_reverse: Reverse(attribute.clone()),
                    package_attr_name_query: AttributeQuery::new(&attribute),
                    package_attr_name_query_reverse: Reverse(AttributeQuery::new(&attribute)),
                    package_attr_set,
                    package_attr_set_reverse,
                    package_pname: package.pname.clone(),
                    package_pname_reverse: Reverse(package.pname),
                    package_pversion: package.version,
                    package_platforms: package
                        .meta
                        .platforms
                        .map(Flatten::flatten)
                        .unwrap_or_default(),
                    package_outputs: package.meta.outputs.unwrap_or_default(),
                    package_license,
                    package_license_set,
                    package_maintainers,
                    package_maintainers_set,
                    package_description: package.meta.description.clone(),
                    package_description_reverse: package.meta.description.map(Reverse),
                    package_longDescription: package.meta.long_description.clone(),
                    package_longDescription_reverse: package.meta.long_description.map(Reverse),
                    package_hydra: (),
                    package_system: package.system,
                    package_homepage: package
                        .meta
                        .homepage
                        .map_or(Default::default(), OneOrMany::into_list),
                    package_position: position,
                }
            }
            import::NixpkgsEntry::Option(option) => option.into(),
        }
    }
}

impl From<import::NixOption> for Derivation {
    fn from(
        NixOption {
            declarations,
            description,
            name,
            option_type,
            default,
            example,
            flake,
        }: import::NixOption,
    ) -> Self {
        let citeref_filter = {
            let mut p = FILTERS_PATH.clone();
            p.push("docbook-reader/citerefentry-to-rst-role.lua");
            p
        };
        let man_filter = {
            let mut p = FILTERS_PATH.clone();
            p.push("link-unix-man-references.lua");
            p
        };

        let description = if let Some(description) = description {
            let mut pandoc = pandoc::new();
            let description_xml = format!(
                "
                <xml xmlns:xlink=\"http://www.w3.org/1999/xlink\">
                <para>{}</para>
                </xml>
                ", description
            );


            pandoc.set_input(InputKind::Pipe(description_xml));
            pandoc.set_input_format(InputFormat::DocBook, Vec::new());
            pandoc.set_output(OutputKind::Pipe);
            pandoc.set_output_format(OutputFormat::Html, Vec::new());
            pandoc.add_options(&[
                PandocOption::LuaFilter(citeref_filter),
                PandocOption::LuaFilter(man_filter),
            ]);

            let result = pandoc.execute().unwrap();
            match result {
                PandocOutput::ToBuffer(description) => Some(description),
                _ => unreachable!(),
            }
        } else {
            description
        };

        Derivation::Option {
            option_source: declarations.get(0).map(Clone::clone),
            option_name: name.clone(),
            option_name_reverse: Reverse(name.clone()),
            option_description: description.clone(),
            option_description_reverse: description.map(Reverse),
            option_default: default.map(print_value),
            option_example: example.map(print_value),
            option_flake: flake,
            option_type,
            option_name_query: AttributeQuery::new(&name),
            option_name_query_reverse: Reverse(AttributeQuery::new(&name)),
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

// ----- output type

/// Export type that brings together derivation and optional flake info
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Export {
    #[serde(flatten)]
    flake: Option<Flake>,

    #[serde(flatten)]
    item: Derivation,
}

impl Export {
    /// Construct Export from Flake and Flake entry
    pub fn flake(flake: Flake, item: import::FlakeEntry) -> Self {
        Self {
            flake: Some(flake.clone()),
            item: Derivation::from((item, flake)),
        }
    }

    /// Construct Export from NixpkgsEntry
    pub fn nixpkgs(item: import::NixpkgsEntry) -> Self {
        Self {
            flake: None,
            item: Derivation::from(item),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_option() {
        let option: NixOption = serde_json::from_str(r#"
        {
            "declarations":["/nix/store/s1q1238ahiks5a4g6j6qhhfb3rlmamvz-source/nixos/modules/system/boot/luksroot.nix"],
            "default":"",
            "description":"Commands that should be run right after we have mounted our LUKS device.\n",
            "example":"oneline\ntwoline\nthreeline\n",
            "internal":false,
            "loc":["boot","initrd","luks","devices","<name>","postOpenCommands"],
            "name":"boot.initrd.luks.devices.<name>.postOpenCommands",
            "readOnly":false,"type":
            "strings concatenated with \"\\n\"","visible":true
        }"#).unwrap();

        let option: Derivation = option.into();

        println!("{}", serde_json::to_string_pretty(&option).unwrap());
    }
}
