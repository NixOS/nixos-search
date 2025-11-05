/// This module defines the unified output format we use to store information in elastic search
/// Additionally, we implement converseions from the two possible input formats, i.e.
/// Flakes, or Nixpkgs.
///
/// The output format can be kept as simple as possible and does
/// not need to use utilities like OneOrMany, as we can evolve 
/// the schema and keep it as simple as possible.
///
/// When merging a PR that changes the schema, also update the
/// version.nix `import` version in the root of the repo,
/// so a fresh index will be created.

use std::{
    collections::HashSet,
    convert::{TryFrom, TryInto},
    path::PathBuf,
};

use serde::{Deserialize, Serialize};

use super::{
    import::{self, DocString, DocValue, ModulePath, NixOption},
    pandoc::PandocExt,
    utility::{Flatten, OneOrMany},
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
                fullName: "no license specified".to_string(),
            },
            import::License::Simple { license } => License {
                url: None,
                fullName: license,
            },
            import::License::Full {
                fullName,
                shortName,
                url,
            } => License {
                url,
                fullName: fullName.unwrap_or(shortName.unwrap_or("custom".into())),
            },
        }
    }
}

// ----- Unified derivation representation

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum Derivation {
    #[serde(rename = "package")]
    #[allow(non_snake_case)]
    Package {
        package_attr_name: String,
        package_attr_set: String,
        package_pname: String,
        package_pversion: String,
        package_platforms: Vec<String>,
        package_outputs: Vec<String>,
        package_default_output: Option<String>,
        package_programs: Vec<String>,
        package_mainProgram: Option<String>,
        package_license: Vec<License>,
        package_license_set: Vec<String>,
        package_maintainers: Vec<Maintainer>,
        package_maintainers_set: Vec<String>,
        package_teams: Vec<Team>,
        package_teams_set: Vec<String>,
        package_description: Option<String>,
        package_longDescription: Option<String>,
        package_hydra: (),
        package_system: String,
        package_homepage: Vec<String>,
        package_position: Option<String>,
    },
    #[serde(rename = "app")]
    App {
        app_attr_name: String,
        app_platforms: Vec<String>,

        app_type: Option<String>,

        app_bin: Option<PathBuf>,
    },
    #[serde(rename = "option")]
    Option {
        option_source: Option<String>,
        option_name: String,

        option_description: Option<DocString>,

        option_type: Option<String>,

        option_default: Option<DocValue>,

        option_example: Option<DocValue>,

        option_flake: Option<ModulePath>,
    },
}

// ----- Conversions

impl TryFrom<(import::FlakeEntry, super::Flake)> for Derivation {
    type Error = anyhow::Error;

    fn try_from((d, f): (import::FlakeEntry, super::Flake)) -> Result<Self, Self::Error> {
        Ok(match d {
            import::FlakeEntry::Package {
                attribute_name,
                name,
                version,
                platforms,
                outputs,
                default_output,
                description,
                long_description,
                license,
            } => {
                let package_attr_set: Vec<_> = attribute_name.split(".").collect();
                let package_attr_set: String = (if package_attr_set.len() > 1 {
                    package_attr_set[0]
                } else {
                    "No package set"
                })
                .into();

                let long_description = long_description.map(|s| s.render_markdown()).transpose()?;

                let package_license: Vec<License> = license
                    .map(OneOrMany::into_list)
                    .unwrap_or_default()
                    .into_iter()
                    .map(|sos| sos.0.into())
                    .collect();
                let package_license_set: Vec<String> = package_license
                    .iter()
                    .clone()
                    .map(|l| l.fullName.to_owned())
                    .collect();

                let maintainer: Maintainer = f.into();

                Derivation::Package {
                    package_attr_name: attribute_name.clone(),
                    package_attr_set,
                    package_pname: name.clone(),
                    package_pversion: version,
                    package_platforms: platforms,
                    package_outputs: outputs,
                    package_default_output: Some(default_output),
                    package_programs: Vec::new(),
                    package_mainProgram: None,
                    package_license,
                    package_license_set,
                    package_description: description.clone(),
                    package_maintainers: vec![maintainer.clone()],
                    package_maintainers_set: maintainer.name.map_or(vec![], |n| vec![n]),
                    package_teams: Vec::new(),
                    package_teams_set: Vec::new(),
                    package_longDescription: long_description,
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
            import::FlakeEntry::Option(option) => option.try_into()?,
        })
    }
}

impl TryFrom<import::NixpkgsEntry> for Derivation {
    type Error = anyhow::Error;

    fn try_from(entry: import::NixpkgsEntry) -> Result<Self, Self::Error> {
        Ok(match entry {
            import::NixpkgsEntry::Derivation {
                attribute,
                package,
                programs,
            } => {
                let package_attr_set: Vec<_> = attribute.split(".").collect();
                let package_attr_set: String = (if package_attr_set.len() > 1 {
                    package_attr_set[0]
                } else {
                    "No package set"
                })
                .into();

                let package_license: Vec<License> = package
                    .meta
                    .license
                    .map_or(Default::default(), OneOrMany::into_list)
                    .into_iter()
                    .map(|sos| sos.0.into())
                    .collect();

                let package_license_set = package_license
                    .iter()
                    .map(|l: &License| l.fullName.to_owned())
                    .collect();

                let platforms: HashSet<String> =
                    package.meta.platforms.unwrap_or_default().collect();

                let bad_platforms: HashSet<String> =
                    package.meta.bad_platforms.unwrap_or_default().collect();

                let platforms: Vec<String> =
                    platforms.difference(&bad_platforms).cloned().collect();

                let package_maintainers: Vec<Maintainer> = package
                    .meta
                    .maintainers
                    .map_or(Default::default(), Flatten::flatten)
                    .into_iter()
                    .map(Into::into)
                    .collect();

                let package_maintainers_set = package_maintainers
                    .iter()
                    .flat_map(|m| m.name.to_owned())
                    .collect();

                let package_teams: Vec<Team> = package
                    .meta
                    .teams
                    .map_or(Default::default(), Flatten::flatten)
                    .into_iter()
                    .map(Into::into)
                    .collect();

                let package_teams_set = package_teams
                    .iter()
                    .flat_map(|m| m.shortName.to_owned())
                    .collect();

                let long_description = package
                    .meta
                    .long_description
                    .map(|s| s.render_markdown())
                    .transpose()?;

                let position: Option<String> = package.meta.position.map(|p| {
                    if p.starts_with("/nix/store") {
                        p.split("/").skip(4).collect::<Vec<&str>>().join("/")
                    } else {
                        p
                    }
                });

                Derivation::Package {
                    package_attr_name: attribute.clone(),
                    package_attr_set,
                    package_pname: package.pname.clone(),
                    package_pversion: package.version,
                    package_platforms: platforms,
                    package_outputs: package.outputs.into_keys().collect(),
                    package_default_output: package.default_output,
                    package_programs: programs,
                    package_mainProgram: package.meta.mainProgram,
                    package_license,
                    package_license_set,
                    package_maintainers,
                    package_maintainers_set,
                    package_teams,
                    package_teams_set,
                    package_description: package.meta.description.clone(),
                    package_longDescription: long_description,
                    package_hydra: (),
                    package_system: package.system,
                    package_homepage: package
                        .meta
                        .homepage
                        .map_or(Default::default(), OneOrMany::into_list),
                    package_position: position,
                }
            }
            import::NixpkgsEntry::Option(option) => option.try_into()?,
        })
    }
}

impl TryFrom<import::NixOption> for Derivation {
    type Error = anyhow::Error;

    fn try_from(
        NixOption {
            declarations,
            description,
            name,
            option_type,
            default,
            example,
            flake,
        }: import::NixOption,
    ) -> Result<Self, Self::Error> {
        Ok(Derivation::Option {
            option_source: declarations.get(0).map(Clone::clone),
            option_name: name.clone(),
            option_description: description,
            option_default: default,
            option_example: example,
            option_flake: flake,
            option_type,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Maintainer {
    name: Option<String>,
    github: Option<String>,
    email: Option<String>,
}

impl From<import::Maintainer> for Maintainer {
    fn from(import: import::Maintainer) -> Self {
        match import {
            import::Maintainer::Full {
                name,
                github,
                email,
            } => Maintainer {
                name,
                github,
                email,
            },
            import::Maintainer::Simple(name) => Maintainer {
                name: Some(name),
                github: None,
                email: None,
            },
        }
    }
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
            github: Some(github),
            email: None,
            name: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[allow(non_snake_case)]
pub struct Team {
    members: Vec<Maintainer>,
    scope: Option<String>,
    shortName: Option<String>,
    githubTeams: Vec<String>,
}

impl From<import::Team> for Team {
    fn from(import: import::Team) -> Self {
        match import {
            import::Team::Full {
                members,
                scope,
                shortName,
                githubTeams,
            } =>
              Team {
                  members: members
                      .map(OneOrMany::into_list)
                      .unwrap_or_default()
                      .into_iter()
                      .map(Maintainer::from)
                      .collect(),
                  scope,
                  shortName,
                  githubTeams: githubTeams
                      .map(OneOrMany::into_list)
                      .unwrap_or_default()
                      .into_iter()
                      .collect(),
              },
            #[allow(non_snake_case)]
            import::Team::Simple(shortName) => Team {
                shortName: Some(shortName),
                scope: None,
                members: Vec::new(),
                githubTeams: Vec::new(),
            },
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
    pub fn flake(flake: Flake, item: import::FlakeEntry) -> anyhow::Result<Self> {
        Ok(Self {
            flake: Some(flake.clone()),
            item: Derivation::try_from((item, flake))?,
        })
    }

    /// Construct Export from NixpkgsEntry
    pub fn nixpkgs(item: import::NixpkgsEntry) -> anyhow::Result<Self> {
        Ok(Self {
            flake: None,
            item: Derivation::try_from(item)?,
        })
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
            "default": {"one": 1, "two" : { "three": "tree", "four": []}},
            "description":"Commands that should be run right after we have mounted our LUKS device.\n",
            "example":null,
            "internal":false,
            "loc":["boot","initrd","luks","devices","<name>","postOpenCommands"],
            "name":"boot.initrd.luks.devices.<name>.postOpenCommands",
            "readOnly":false,
            "type": "boolean",
            "visible":true
        }"#).unwrap();

        let option: Derivation = option.try_into().unwrap();

        println!("{}", serde_json::to_string_pretty(&option).unwrap());
    }
}
