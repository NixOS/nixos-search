use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use super::Source;

/// Holds general infoamtion about a flake
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Flake {
    #[serde(rename(serialize = "flake_description"))]
    pub description: Option<String>,
    #[serde(default, rename(serialize = "flake_path"), skip_serializing)]
    pub path: PathBuf,
    #[serde(rename(serialize = "flake_resolved"))]
    pub resolved: Repo,

    #[serde(rename(serialize = "flake_name"), skip_deserializing)]
    pub name: String,

    pub revision: Option<String>,

    #[serde(
        skip_deserializing,
        rename(serialize = "flake_source"),
        skip_serializing_if = "Option::is_none"
    )]
    pub source: Option<Source>,
}

impl Flake {
    pub(crate) fn resolve_name(mut self) -> Self {
        self.name = match &self.resolved {
            // Use the last path segment of the URL without a `.git` suffix
            Repo::Git { url } => url
                .file_name()
                .and_then(|name| name.to_str())
                .map(|name| name.strip_suffix(".git").unwrap_or(name).to_owned())
                .unwrap_or_default(),
            Repo::GitHub { repo, .. } => repo.clone(),
            Repo::Gitlab { repo, .. } => repo.clone(),
            Repo::SourceHut { repo, .. } => repo.clone(),
        };
        self
    }
}

/// Information about the flake origin
/// Supports (local/raw) Git, GitHub, SourceHut and Gitlab repos
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Repo {
    Git { url: PathBuf },
    GitHub { owner: String, repo: String },
    Gitlab { owner: String, repo: String },
    SourceHut { owner: String, repo: String },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gitlab_flake() {
        let nix_info_out = r#"{"description":"neuropil is a secure messaging library for IoT, robotics and more.","lastModified":1616059502,"locked":{"lastModified":1616059502,"narHash":"sha256-fHB1vyjDXQq/E2/Xb6Xs3caAAc0VkUlnzu5kl/PvFW4=","owner":"pi-lar","repo":"neuropil","rev":"9e2f634ffa45da3f5feb158a12ee32e1673bfe35","type":"gitlab"},"original":{"owner":"pi-lar","repo":"neuropil","type":"gitlab"},"originalUrl":"gitlab:pi-lar/neuropil","path":"/nix/store/z4fp2fc9hca40nnvxi0116pfbrla5zgl-source","resolved":{"owner":"pi-lar","repo":"neuropil","type":"gitlab"},"resolvedUrl":"gitlab:pi-lar/neuropil","revision":"9e2f634ffa45da3f5feb158a12ee32e1673bfe35","url":"gitlab:pi-lar/neuropil/9e2f634ffa45da3f5feb158a12ee32e1673bfe35"}"#;

        assert_eq!(
            serde_json::de::from_str::<Flake>(nix_info_out).unwrap(),
            Flake {
                description: Some(
                    "neuropil is a secure messaging library for IoT, robotics and more.".into()
                ),
                path: "/nix/store/z4fp2fc9hca40nnvxi0116pfbrla5zgl-source".into(),
                resolved: Repo::Gitlab {
                    owner: "pi-lar".into(),
                    repo: "neuropil".into()
                },
                name: "".into(),
                source: None,
                revision: Some("9e2f634ffa45da3f5feb158a12ee32e1673bfe35".into())
            }
        );

        assert_eq!(
            serde_json::de::from_str::<Flake>(nix_info_out)
                .unwrap()
                .resolve_name()
                .name,
            "neuropil"
        );
    }

    #[test]
    fn git_flake_name() {
        let name = |resolved: &str| {
            let nix_info_out = format!(r#"{{"description":null,"resolved":{resolved}}}"#);
            serde_json::de::from_str::<Flake>(&nix_info_out)
                .unwrap()
                .resolve_name()
                .name
        };

        assert_eq!(
            name(r#"{"type":"git","url":"https://gitlab.com/pi-lar/neuropil"}"#),
            "neuropil"
        );
        assert_eq!(
            name(
                r#"{"ref":"main","type":"git","url":"https://codeberg.org/alch_emi/embers-nix-packages.git"}"#
            ),
            "embers-nix-packages"
        );
        assert_eq!(
            name(r#"{"type":"git","url":"https://example.org/owner/repo/"}"#),
            "repo"
        );
    }
}
