use std::{fs::{self, File}, path::Path};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

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
    Nixpkgs {
        channel: String,
    },
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
            Source::Nixpkgs { channel } => format!("https://github.com/NixOS/nixpkgs/archive/refs/heads/{}.tar.gz", channel),

        }
    }

    pub fn read_sources_file(path: &Path) -> Result<Vec<Source>> {
        let file = File::open(path).with_context(|| "Failed to open input file")?;

        Ok(serde_json::from_reader(file)?)
    }

}
