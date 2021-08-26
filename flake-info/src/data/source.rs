use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File},
    io::Read,
    path::Path,
    ffi::OsStr,
};

pub type Hash = String;
pub type FlakeRef = String;

/// Information about the flake origin
/// Supports (local/raw) Git, GitHub and Gitlab repos
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Source {
    Github {
        owner: String,
        repo: String,
        description: Option<String>,
        #[serde(rename(deserialize = "hash"))]
        git_ref: Option<Hash>,
    },
    Gitlab {
        owner: String,
        repo: String,
        git_ref: Option<Hash>,
    },
    Git {
        url: String,
    },
    Nixpkgs(Nixpkgs),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct TomlDocument {
    sources: Vec<Source>
}


impl Source {
    pub fn to_flake_ref(&self) -> FlakeRef {
        match self {
            Source::Github {
                owner,
                repo,
                git_ref,
                ..
            } => format!(
                "github:{}/{}{}",
                owner,
                repo,
                git_ref
                    .as_ref()
                    .map_or("".to_string(), |f| format!("?ref={}", f))
            ),
            Source::Gitlab {
                owner,
                repo,
                git_ref,
            } => format!(
                "gitlab:{}/{}{}",
                owner,
                repo,
                git_ref
                    .as_ref()
                    .map_or("".to_string(), |f| format!("?ref={}", f))
            ),
            Source::Git { url } => url.to_string(),
            Source::Nixpkgs(Nixpkgs { git_ref, .. }) => format!(
                "https://api.github.com/repos/NixOS/nixpkgs/tarball/{}",
                git_ref
            ),
        }
    }

    pub fn read_sources_file(path: &Path) -> Result<Vec<Source>> {

        let mut file = File::open(path).with_context(|| "Failed to open input file")?;
       
        let mut buf = String::new();
        file.read_to_string(&mut buf)?;
        
        if path.extension() == Some(OsStr::new("toml")) {
            let document: TomlDocument = toml::from_str(&buf)?;
            Ok(document.sources)
        }
        else {
            Ok(serde_json::from_str(&buf)?)
        }
    }

    pub async fn nixpkgs(channel: String) -> Result<Nixpkgs> {
        #[derive(Deserialize, Debug)]
        struct ApiResult {
            commit: Commit,
        }

        #[derive(Deserialize, Debug)]
        struct Commit {
            sha: String,
        }

        let git_ref = reqwest::Client::builder()
            .user_agent("curl") // thank you github
            .build()?
            .get(format!(
                "https://api.github.com/repos/nixos/nixpkgs/branches/nixos-{}",
                channel
            ))
            .send()
            .await?
            .json::<ApiResult>()
            .await?
            .commit
            .sha;

        let nixpkgs = Nixpkgs { channel, git_ref };

        Ok(nixpkgs)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Nixpkgs {
    pub channel: String,
    pub git_ref: String,
}
