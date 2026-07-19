use std::collections::{HashMap, HashSet};
use std::thread::sleep;
use std::time::Duration;

use anyhow::{Context, Result};
use log::info;
use serde::Deserialize;

const API_BASE: &str = "https://repology.org/api/v1/projects/";
const REPOLOGY_REPO: &str = "nix_unstable";
const USER_AGENT: &str = "nixos-search (https://github.com/NixOS/nixos-search)";
const REQUEST_DELAY: Duration = Duration::from_secs(1);

/// Subset of a Repology package entry.
#[derive(Debug, Deserialize)]
struct RepologyPackage {
    repo: String,
    srcname: Option<String>,
}

type RepologyPage = HashMap<String, Vec<RepologyPackage>>;

/// Number of Repology repositories packaging each nixpkgs attribute, used as
/// the `package_repology_repos` popularity signal. Always queries the
/// unstable nixpkgs repository, since the signal only reflects overall
/// popularity, not the exact channel contents.
pub fn get_repology_repo_counts() -> Result<HashMap<String, u64>> {
    info!("Fetching Repology repository counts for {}", REPOLOGY_REPO);

    let client = reqwest::blocking::Client::builder()
        .user_agent(USER_AGENT)
        .build()?;

    let mut counts: HashMap<String, u64> = HashMap::new();
    let mut cursor = String::new();
    loop {
        let url = format!("{}{}?inrepo={}", API_BASE, cursor, REPOLOGY_REPO);
        let page: RepologyPage = client
            .get(&url)
            .send()
            .and_then(reqwest::blocking::Response::error_for_status)
            .with_context(|| format!("Failed to fetch {}", url))?
            .json()
            .with_context(|| format!("Could not parse Repology response from {}", url))?;

        // The last project of a page is repeated as the first of the next,
        // so a page with a single project is the final one.
        let next = match page.keys().max() {
            Some(name) if page.len() > 1 => Some(format!("{}/", name)),
            _ => None,
        };
        merge_page_counts(&mut counts, page);
        match next {
            Some(next) => cursor = next,
            None => break,
        }
        sleep(REQUEST_DELAY);
    }

    info!("Repology counts cover {} attributes", counts.len());
    Ok(counts)
}

/// Fold one API page into the attribute counts. A project's score is the
/// number of distinct repositories packaging it, and it is assigned to every
/// nixpkgs attribute (srcname) the project maps to. Attributes appearing in
/// multiple projects keep the highest score.
fn merge_page_counts(counts: &mut HashMap<String, u64>, page: RepologyPage) {
    for packages in page.into_values() {
        let repos: HashSet<&str> = packages.iter().map(|p| p.repo.as_str()).collect();
        let count = repos.len() as u64;
        for package in &packages {
            if package.repo != REPOLOGY_REPO {
                continue;
            }
            let Some(attr) = &package.srcname else {
                continue;
            };
            let entry = counts.entry(attr.clone()).or_default();
            *entry = (*entry).max(count);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_merge_page_counts() {
        let page: RepologyPage = serde_json::from_str(
            r#"{
                "7zip": [
                    {"repo": "nix_unstable", "srcname": "_7zz", "visiblename": "7zz"},
                    {"repo": "nix_unstable", "srcname": "_7zz-rar", "visiblename": "7zz"},
                    {"repo": "nix_stable_25_05", "srcname": "_7zz", "visiblename": "7zz"},
                    {"repo": "debian_13", "srcname": "7zip", "visiblename": "7zip"},
                    {"repo": "freebsd", "srcname": "archivers/7-zip", "visiblename": "7-zip"}
                ],
                "no-nix-src": [
                    {"repo": "nix_unstable"},
                    {"repo": "debian_13", "srcname": "no-nix-src"}
                ],
                "other-distro-only": [
                    {"repo": "debian_13", "srcname": "other"}
                ]
            }"#,
        )
        .unwrap();

        let mut counts = HashMap::new();
        merge_page_counts(&mut counts, page);

        assert_eq!(counts.get("_7zz"), Some(&4));
        assert_eq!(counts.get("_7zz-rar"), Some(&4));
        assert_eq!(counts.len(), 2);
    }
}
