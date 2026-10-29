//! The `User-Agent` every outbound HTTP client in flake-info identifies with.

/// Sent to repology.org, the GitHub API and channels.nixos.org. Forks and
/// one-off runs should override it rather than impersonate nixos-search.
pub const DEFAULT_USER_AGENT: &str = "nixos-search (https://github.com/NixOS/nixos-search)";

/// Resolve a caller-supplied override against the default.
pub fn resolve(user_agent: Option<&str>) -> &str {
    user_agent.unwrap_or(DEFAULT_USER_AGENT)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_falls_back_to_default() {
        assert_eq!(resolve(None), DEFAULT_USER_AGENT);
    }

    #[test]
    fn resolve_prefers_override() {
        assert_eq!(resolve(Some("x")), "x");
    }
}
