//! Carry a package's popularity across to the options that configure it.
//!
//! A package document is ranked partly on `package_repology_repos`, the number
//! of distribution repositories that carry the package. An option document has
//! no comparable signal: nothing in the index says that `services.nginx.enable`
//! is asked for more often than `services.lighttpd.enable`, so a query that
//! matches both can only be broken apart by name length or by Lucene's tie
//! order.
//!
//! The link between the two is a convention nixpkgs already follows. A module
//! that wraps a package declares which one under `<module path>.package`, with
//! the package itself as the default:
//!
//! ```text
//! services.nginx.package    default: pkgs.nginxStable
//! services.postgresql.package    default: pkgs.postgresql_15
//! ```
//!
//! So every option under `services.nginx` can be attributed to `nginxStable`
//! by walking up its own name until a `.package` sibling is found, and take
//! that package's repository count as its own. Modular service options say it
//! directly through `service_package` and skip the walk.

use std::collections::HashMap;

use crate::data::import::{NixOption, NixpkgsEntry};

/// The prefix of a `<...>.package` option, i.e. the module it belongs to.
const PACKAGE_LEAF: &str = ".package";

/// The attribute path a `pkgs.` reference opens with: `pkgs.nginxStable`,
/// `pkgs.postgresql_15`, `pkgs.php83Packages.composer`. A default that is not
/// a plain reference - a function call, a `let`, a conditional - has no one
/// package to name, and yields none.
///
/// What comes back is what was written, which for `pkgs.hello.override { }` is
/// `hello.override`. Telling a nested attribute from a method call is not a
/// job for a parser this size, so [`resolve`] settles it against the packages
/// that actually exist.
fn pkgs_attribute(default: &str) -> Option<&str> {
    let rest = default.strip_prefix("pkgs.")?;
    let end = rest
        .find(|c: char| !(c.is_ascii_alphanumeric() || "._'-".contains(c)))
        .unwrap_or(rest.len());
    let attribute = rest[..end].trim_end_matches('.');
    (!attribute.is_empty()).then_some(attribute)
}

/// The longest prefix of a dotted attribute path that names a real package, so
/// `hello.override` finds `hello` while `php83Packages.composer` stays whole.
fn resolve<'a>(attribute: &'a str, packages: &HashMap<&str, Option<u64>>) -> Option<&'a str> {
    std::iter::once(attribute)
        .chain(ancestors(attribute))
        .find(|candidate| packages.contains_key(candidate))
}

/// Every ancestor of an option name, longest first, so the nearest enclosing
/// module wins: `services.nginx.virtualHosts.foo.root` tries
/// `services.nginx.virtualHosts.foo`, then `services.nginx.virtualHosts`, then
/// `services.nginx`, then `services`.
fn ancestors(name: &str) -> impl Iterator<Item = &str> {
    name.char_indices()
        .filter(|(_, c)| *c == '.')
        .map(|(i, _)| &name[..i])
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
}

/// `<module> -> <package attribute>`, read off the `*.package` options.
fn module_packages<'a>(options: impl Iterator<Item = &'a NixOption>) -> HashMap<&'a str, String> {
    let mut modules = HashMap::new();
    for option in options {
        let Some(module) = option.name.strip_suffix(PACKAGE_LEAF) else {
            continue;
        };
        // `types.package` only. A `nullOr package` or a list of them does not
        // name one idiomatic package, and `str` under a `.package` name is
        // something else entirely.
        if option.option_type.as_deref() != Some("package") {
            continue;
        }
        let Some(default) = option.default.as_ref().map(|d| d.as_text()) else {
            continue;
        };
        if let Some(attribute) = pkgs_attribute(&default) {
            modules.insert(module, attribute.to_owned());
        }
    }
    modules
}

/// Attribute the options in `entries` to a package and stamp each one with that
/// package's repository count, in place.
pub fn assign(entries: &mut [NixpkgsEntry]) {
    let packages: HashMap<&str, Option<u64>> = entries
        .iter()
        .filter_map(|entry| match entry {
            NixpkgsEntry::Derivation {
                attribute,
                repology_repos,
                ..
            } => Some((attribute.as_str(), *repology_repos)),
            _ => None,
        })
        .collect();

    let modules = module_packages(entries.iter().filter_map(option_of));

    let mut assignments = Vec::with_capacity(entries.len());
    for entry in entries.iter() {
        assignments.push(option_of(entry).and_then(|option| {
            // A modular service names its package outright; everything else is
            // attributed to the nearest module that declares one.
            let written = match option.service_package.as_deref() {
                Some(package) => package,
                None => ancestors(&option.name)
                    .find_map(|module| modules.get(module))
                    .map(String::as_str)?,
            };
            let attribute = resolve(written, &packages)?;
            Some((attribute.to_owned(), packages[attribute]))
        }));
    }

    for (entry, assignment) in entries.iter_mut().zip(assignments) {
        let Some((package, popularity)) = assignment else {
            continue;
        };
        if let Some(option) = option_of_mut(entry) {
            option.package = Some(package);
            option.popularity = popularity;
        }
    }
}

fn option_of(entry: &NixpkgsEntry) -> Option<&NixOption> {
    match entry {
        NixpkgsEntry::Option(option)
        | NixpkgsEntry::Service(option)
        | NixpkgsEntry::HomeManagerOption(option)
        | NixpkgsEntry::DarwinOption(option) => Some(option),
        NixpkgsEntry::Derivation { .. } => None,
    }
}

fn option_of_mut(entry: &mut NixpkgsEntry) -> Option<&mut NixOption> {
    match entry {
        NixpkgsEntry::Option(option)
        | NixpkgsEntry::Service(option)
        | NixpkgsEntry::HomeManagerOption(option)
        | NixpkgsEntry::DarwinOption(option) => Some(option),
        NixpkgsEntry::Derivation { .. } => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::data::import::{DocValue, Literal};

    fn option(name: &str, option_type: Option<&str>, default: Option<&str>) -> NixOption {
        NixOption {
            declarations: vec![],
            description: None,
            name: name.to_owned(),
            option_type: option_type.map(str::to_owned),
            default: default.map(|d| DocValue::Literal(Literal::LiteralExpression(d.to_owned()))),
            example: None,
            flake: None,
            package: None,
            popularity: None,
            service_package: None,
            service_module: None,
            service_packages: vec![],
        }
    }

    fn derivation(attribute: &str, repology_repos: Option<u64>) -> NixpkgsEntry {
        NixpkgsEntry::Derivation {
            attribute: attribute.to_owned(),
            package: serde_json::from_str(r#"{"pname":"p","version":"1","system":"x86_64-linux"}"#)
                .unwrap(),
            programs: vec![],
            modular_services: vec![],
            dep_count: None,
            repology_repos,
        }
    }

    #[test]
    fn reads_an_attribute_out_of_a_default() {
        assert_eq!(pkgs_attribute("pkgs.nginxStable"), Some("nginxStable"));
        assert_eq!(pkgs_attribute("pkgs.postgresql_15"), Some("postgresql_15"));
        assert_eq!(
            pkgs_attribute("pkgs.php83Packages.composer"),
            Some("php83Packages.composer")
        );
        assert_eq!(
            pkgs_attribute("pkgs.hello.override { }"),
            Some("hello.override")
        );
        assert_eq!(pkgs_attribute("config.boot.kernelPackages"), None);
        assert_eq!(pkgs_attribute("pkgs."), None);
        assert_eq!(pkgs_attribute("null"), None);
    }

    #[test]
    fn resolves_a_method_call_back_to_its_package() {
        let packages = HashMap::from([("hello", Some(200)), ("php83Packages.composer", Some(20))]);
        assert_eq!(resolve("hello.override", &packages), Some("hello"));
        assert_eq!(
            resolve("php83Packages.composer", &packages),
            Some("php83Packages.composer")
        );
        assert_eq!(resolve("notInNixpkgs", &packages), None);
    }

    #[test]
    fn walks_ancestors_nearest_first() {
        assert_eq!(
            ancestors("services.nginx.virtualHosts.foo").collect::<Vec<_>>(),
            vec!["services.nginx.virtualHosts", "services.nginx", "services"]
        );
        assert!(ancestors("services").next().is_none());
    }

    #[test]
    fn attributes_an_option_to_its_nearest_module() {
        let mut entries = vec![
            derivation("nginxStable", Some(149)),
            derivation("nginxMainline", Some(3)),
            NixpkgsEntry::Option(option(
                "services.nginx.package",
                Some("package"),
                Some("pkgs.nginxStable"),
            )),
            NixpkgsEntry::Option(option("services.nginx.enable", Some("boolean"), None)),
            NixpkgsEntry::Option(option(
                "services.nginx.virtualHosts.<name>.root",
                Some("path"),
                None,
            )),
            NixpkgsEntry::Option(option("services.lighttpd.enable", Some("boolean"), None)),
        ];
        assign(&mut entries);

        let assigned = |i: usize| {
            option_of(&entries[i])
                .map(|o| (o.package.clone(), o.popularity))
                .unwrap()
        };
        assert_eq!(assigned(3), (Some("nginxStable".to_owned()), Some(149)));
        assert_eq!(assigned(4), (Some("nginxStable".to_owned()), Some(149)));
        // No module below it declares a package, so it stays unattributed
        // rather than inheriting one from `services`.
        assert_eq!(assigned(5), (None, None));
    }

    #[test]
    fn prefers_the_innermost_module() {
        let mut entries = vec![
            derivation("php", Some(80)),
            derivation("composer", Some(20)),
            NixpkgsEntry::Option(option(
                "services.php.package",
                Some("package"),
                Some("pkgs.php"),
            )),
            NixpkgsEntry::Option(option(
                "services.php.composer.package",
                Some("package"),
                Some("pkgs.composer"),
            )),
            NixpkgsEntry::Option(option(
                "services.php.composer.enable",
                Some("boolean"),
                None,
            )),
        ];
        assign(&mut entries);
        assert_eq!(
            option_of(&entries[4]).map(|o| (o.package.clone(), o.popularity)),
            Some((Some("composer".to_owned()), Some(20)))
        );
    }

    #[test]
    fn a_modular_service_names_its_own_package() {
        let mut entries = vec![derivation("nginx", Some(149)), {
            let mut option = option("autoconnect.settings", Some("attrs"), None);
            option.service_package = Some("nginx".to_owned());
            NixpkgsEntry::Service(option)
        }];
        assign(&mut entries);
        assert_eq!(
            option_of(&entries[1]).map(|o| (o.package.clone(), o.popularity)),
            Some((Some("nginx".to_owned()), Some(149)))
        );
    }

    #[test]
    fn keeps_the_package_when_repology_has_no_count_for_it() {
        let mut entries = vec![
            derivation("obscure", None),
            NixpkgsEntry::Option(option(
                "services.obscure.package",
                Some("package"),
                Some("pkgs.obscure"),
            )),
            NixpkgsEntry::Option(option("services.obscure.enable", Some("boolean"), None)),
        ];
        assign(&mut entries);
        assert_eq!(
            option_of(&entries[2]).map(|o| (o.package.clone(), o.popularity)),
            Some((Some("obscure".to_owned()), None))
        );
    }

    #[test]
    fn ignores_a_package_option_that_is_not_one() {
        let mut entries = vec![
            derivation("nginx", Some(149)),
            NixpkgsEntry::Option(option(
                "services.nginx.package",
                Some("null or package"),
                Some("pkgs.nginx"),
            )),
            NixpkgsEntry::Option(option("services.nginx.enable", Some("boolean"), None)),
        ];
        assign(&mut entries);
        assert_eq!(
            option_of(&entries[2]).map(|o| (o.package.clone(), o.popularity)),
            Some((None, None))
        );
    }
}
