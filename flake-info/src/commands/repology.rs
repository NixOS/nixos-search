use std::collections::{HashMap, HashSet};
use std::thread::sleep;
use std::time::Duration;

use anyhow::Result;
use log::{info, warn};
use reqwest::StatusCode;
use reqwest::header::{HeaderMap, RETRY_AFTER};
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
        let page = fetch_page(&client, &url)?;

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

/// Maximum fetch attempts per page before giving up. When exhausted, the error
/// propagates and the whole Repology signal is dropped (best-effort).
const MAX_ATTEMPTS: u32 = 5;
/// Base unit for exponential backoff between retries.
const RETRY_BASE_DELAY: Duration = Duration::from_secs(1);
/// Ceiling on any single backoff wait, including a `Retry-After` value.
const MAX_RETRY_DELAY: Duration = Duration::from_secs(60);

/// A failed page fetch, tagged with whether a retry might help and any
/// server-provided delay (from a 429 `Retry-After` header).
struct FetchError {
    error: anyhow::Error,
    retryable: bool,
    retry_after: Option<Duration>,
}

/// Fetch and decode one projects page, retrying transient failures (network
/// errors, HTTP 429, and 5xx) with exponential backoff plus jitter. A 429
/// `Retry-After` value, when present, replaces the computed delay. Permanent
/// failures (non-429 4xx) and exhausted retries return `Err`, which drops the
/// entire Repology signal upstream instead of failing the import.
fn fetch_page(client: &reqwest::blocking::Client, url: &str) -> Result<RepologyPage> {
    let mut attempt = 1;
    loop {
        match try_fetch_page(client, url) {
            Ok(page) => return Ok(page),
            Err(failure) => {
                if attempt >= MAX_ATTEMPTS || !failure.retryable {
                    return Err(failure.error);
                }
                let delay = failure
                    .retry_after
                    .unwrap_or_else(|| backoff_delay(attempt) + jitter())
                    .min(MAX_RETRY_DELAY);
                warn!(
                    "Repology fetch attempt {}/{} for {} failed ({:#}); retrying in {:?}",
                    attempt, MAX_ATTEMPTS, url, failure.error, delay
                );
                sleep(delay);
                attempt += 1;
            }
        }
    }
}

/// Perform a single fetch attempt, classifying any failure for the retry loop.
fn try_fetch_page(
    client: &reqwest::blocking::Client,
    url: &str,
) -> std::result::Result<RepologyPage, FetchError> {
    // Connection resets, timeouts, and DNS blips carry no status and are transient.
    let response = match client.get(url).send() {
        Ok(response) => response,
        Err(error) => {
            return Err(FetchError {
                error: anyhow::Error::new(error).context(format!("Request to {} failed", url)),
                retryable: true,
                retry_after: None,
            });
        }
    };

    let status = response.status();
    if status.is_success() {
        // A truncated body from a dropped connection surfaces as a decode error,
        // so treat parse failures as transient as well.
        return response.json::<RepologyPage>().map_err(|error| FetchError {
            error: anyhow::Error::new(error)
                .context(format!("Could not parse Repology response from {}", url)),
            retryable: true,
            retry_after: None,
        });
    }

    let retry_after = if status == StatusCode::TOO_MANY_REQUESTS {
        parse_retry_after(response.headers())
    } else {
        None
    };
    Err(FetchError {
        error: anyhow::anyhow!("{} returned HTTP {}", url, status),
        retryable: is_retryable_status(status),
        retry_after,
    })
}

/// An unsuccessful status is worth retrying only for rate limiting (429) and
/// server errors (5xx); other 4xx responses will not fix themselves.
fn is_retryable_status(status: StatusCode) -> bool {
    status == StatusCode::TOO_MANY_REQUESTS || status.is_server_error()
}

/// Parse a `Retry-After` header given as an integer number of seconds. The
/// HTTP-date form is ignored, falling back to exponential backoff.
fn parse_retry_after(headers: &HeaderMap) -> Option<Duration> {
    let seconds: u64 = headers
        .get(RETRY_AFTER)?
        .to_str()
        .ok()?
        .trim()
        .parse()
        .ok()?;
    Some(Duration::from_secs(seconds))
}

/// Deterministic exponential backoff for a 1-based attempt number, capped at
/// `MAX_RETRY_DELAY`. Jitter is added separately at the call site.
fn backoff_delay(attempt: u32) -> Duration {
    let factor = 1u64
        .checked_shl(attempt.saturating_sub(1))
        .unwrap_or(u64::MAX);
    Duration::from_secs(RETRY_BASE_DELAY.as_secs().saturating_mul(factor)).min(MAX_RETRY_DELAY)
}

/// Up to one second of clock-seeded jitter, avoiding a dependency purely for
/// backoff randomisation. Cryptographic quality is unnecessary here.
fn jitter() -> Duration {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.subsec_nanos())
        .unwrap_or(0);
    Duration::from_millis(u64::from(nanos % 1_000))
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

    #[test]
    fn test_is_retryable_status() {
        assert!(is_retryable_status(StatusCode::TOO_MANY_REQUESTS));
        assert!(is_retryable_status(StatusCode::INTERNAL_SERVER_ERROR));
        assert!(is_retryable_status(StatusCode::BAD_GATEWAY));
        assert!(!is_retryable_status(StatusCode::BAD_REQUEST));
        assert!(!is_retryable_status(StatusCode::NOT_FOUND));
        assert!(!is_retryable_status(StatusCode::FORBIDDEN));
    }

    #[test]
    fn test_parse_retry_after() {
        use reqwest::header::HeaderValue;

        let mut headers = HeaderMap::new();
        assert_eq!(parse_retry_after(&headers), None);

        headers.insert(RETRY_AFTER, HeaderValue::from_static("30"));
        assert_eq!(parse_retry_after(&headers), Some(Duration::from_secs(30)));

        // The HTTP-date form is not parsed and falls back to backoff.
        headers.insert(
            RETRY_AFTER,
            HeaderValue::from_static("Wed, 21 Oct 2015 07:28:00 GMT"),
        );
        assert_eq!(parse_retry_after(&headers), None);
    }

    #[test]
    fn test_backoff_delay_grows_and_caps() {
        assert_eq!(backoff_delay(1), Duration::from_secs(1));
        assert_eq!(backoff_delay(2), Duration::from_secs(2));
        assert_eq!(backoff_delay(3), Duration::from_secs(4));
        assert_eq!(backoff_delay(4), Duration::from_secs(8));
        // Large attempts saturate at the cap rather than overflowing the shift.
        assert_eq!(backoff_delay(64), MAX_RETRY_DELAY);
        assert_eq!(backoff_delay(1000), MAX_RETRY_DELAY);
    }
}
