use anyhow::{Context, Result, anyhow};
use flake_info::commands::NixCheckError;
use flake_info::data::import::Kind;
use flake_info::data::{self, Export, Source};
use flake_info::elastic::{self, ElasticsearchError, ExistsStrategy};
use log::{info, warn};
use sha2::Digest;
use std::fs::OpenOptions;
use std::io;
use std::io::Write;
use std::path::PathBuf;
use structopt::{StructOpt, clap::ArgGroup};
use thiserror::Error;
use tokio::fs::File;
use tokio::io::AsyncWriteExt;

#[derive(StructOpt, Debug)]
#[structopt(
    name = "flake-info",
    about = "Extracts various information from a given flake",
    group = ArgGroup::with_name("sources").required(false)
)]
struct Args {
    #[structopt(subcommand)]
    command: Command,

    #[structopt(
        short,
        long,
        help = "Kind of data to extract",
        possible_values = &data::import::Kind::variants(),
        case_insensitive = true,
        default_value
    )]
    kind: data::import::Kind,

    #[structopt(
        long = "save-summary",
        help = "Save markdown summary of failures to this file"
    )]
    save_summary: Option<String>,

    #[structopt(
        long = "user-agent",
        env = "FI_USER_AGENT",
        help = "Override the User-Agent sent to repology.org, the GitHub API and \
                channels.nixos.org. Defaults to \
                `nixos-search (https://github.com/NixOS/nixos-search)`"
    )]
    user_agent: Option<String>,

    #[structopt(flatten)]
    elastic: ElasticOpts,

    #[structopt(help = "Extra arguments that are passed to nix as it")]
    extra: Vec<String>,
}

#[derive(StructOpt, Debug)]
enum Command {
    #[structopt(about = "Import a flake")]
    Flake {
        #[structopt(help = "Flake identifier passed to nix to gather information about")]
        flake: String,

        #[structopt(
            long,
            help = "Whether to use a temporary store or not. Located at /tmp/flake-info-store"
        )]
        temp_store: bool,
    },
    #[structopt(about = "Import official nixpkgs channel")]
    Nixpkgs {
        #[structopt(help = "Nixpkgs channel to import")]
        channel: String,

        #[structopt(
            long = "attr",
            help = "Restrict to importing a single attribute. Implies --kind package"
        )]
        attribute: Option<String>,

        #[structopt(
            long = "packages-json-url",
            help = "Override URL to fetch `packages.json` (or `packages.json.br`) from. \
                    Defaults to https://channels.nixos.org/nixos-<channel>/packages.json.br. \
                    Useful for testing a fix against a custom-built file from a nixpkgs branch"
        )]
        packages_json_url: Option<String>,

        #[structopt(
            long = "repology-counts-file",
            help = "Read Repology repository counts (JSON object srcname->count) from this \
                    file instead of crawling repology.org. A missing/unreadable file drops \
                    the signal."
        )]
        repology_counts_file: Option<PathBuf>,
    },

    #[structopt(about = "Import nixpkgs channel from archive or local git path")]
    NixpkgsArchive {
        #[structopt(help = "Nixpkgs archive to import")]
        source: String,

        #[structopt(
            help = "Which channel to assign nixpkgs to",
            default_value = "unstable"
        )]
        channel: String,

        #[structopt(help = "Restrict to importing a single attribute")]
        attribute: Option<String>,
    },

    #[structopt(about = "Load and import a group of flakes from a file")]
    Group {
        #[structopt(
            help = "Points to a TOML or JSON file containing info targets. If file does not end in 'toml' json is assumed"
        )]
        targets: PathBuf,

        name: String,

        #[structopt(
            long,
            help = "Whether to use a temporary store or not. Located at /tmp/flake-info-store"
        )]
        temp_store: bool,

        #[structopt(long, help = "Whether write an error report about failed packages")]
        report: bool,

        #[structopt(
            long,
            help = "Run nix garbage collection between every group member evaluation"
        )]
        with_gc: bool,
    },

    #[structopt(about = "Fetch Repology repository counts and write them as JSON")]
    RepologyCounts {
        #[structopt(short, long, help = "Write JSON to this file instead of stdout")]
        output: Option<PathBuf>,
    },
}

#[derive(StructOpt, Debug)]
struct ElasticOpts {
    #[structopt(long = "json", help = "Print ElasticSeach Compatible JSON output")]
    json: bool,

    #[structopt(
        long = "push",
        help = "Push to Elasticsearch (Configure using FI_ES_* environment variables)",
        requires("elastic-schema-version")
    )]
    enable: bool,

    // #[structopt(
    //     long,
    //     short = "u",
    //     env = "FI_ES_USER",
    //     help = "Elasticsearch username (unimplemented)"
    // )]
    // elastic_user: Option<String>,

    // #[structopt(
    //     long,
    //     short = "p",
    //     env = "FI_ES_PASSWORD",
    //     help = "Elasticsearch password (unimplemented)"
    // )]
    // elastic_pw: Option<String>,
    #[structopt(
        long,
        env = "FI_ES_URL",
        default_value = "http://localhost:9200",
        help = "Elasticsearch instance url"
    )]
    elastic_url: String,

    #[structopt(
        long,
        help = "Name of the index to store results to",
        env = "FI_ES_INDEX",
        required_if("enable", "true")
    )]
    elastic_index_name: Option<String>,

    #[structopt(
        long,
        help = "How to react to existing indices",
        possible_values = &ExistsStrategy::variants(),
        case_insensitive = true,
        default_value = "abort",
        env = "FI_ES_EXISTS_STRATEGY"
    )]
    elastic_exists: ExistsStrategy,

    #[structopt(
        long,
        help = "Which schema version to associate with the operation",
        env = "FI_ES_VERSION"
    )]
    elastic_schema_version: Option<usize>,

    #[structopt(
        long,
        help = "Whether to disable `latest` alias creation",
        env = "FI_ES_NO_ALIAS"
    )]
    no_alias: bool,
}

type LazyExports = Box<dyn FnOnce() -> Result<Vec<Export>, FlakeInfoError> + Send>;

/// Collecting exports shells out and fetches over HTTP through
/// `reqwest::blocking`, which builds a runtime of its own. Dropping such a
/// runtime on the `#[tokio::main]` thread panics with "Cannot drop a runtime in
/// a context where blocking is not allowed", so the thunk runs on a thread where
/// blocking is permitted instead.
async fn collect_exports(exports: LazyExports) -> Result<Vec<Export>> {
    Ok(tokio::task::spawn_blocking(exports)
        .await
        .context("Collecting exports panicked")??)
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init();

    let args = Args::from_args();
    let user_agent = args.user_agent.clone();

    let summary = match args.save_summary {
        Some(filename) => Some(
            OpenOptions::new()
                .create(true)
                .append(true)
                .open(filename)?,
        ),
        None => None,
    };

    // The producer subcommand only crawls Repology and writes JSON; it must be
    // handled before the --push/--json assertion, which does not apply to it.
    if let Command::RepologyCounts { output } = &args.command {
        // `get_repology_repo_counts` uses `reqwest::blocking`, whose internal
        // runtime must not be dropped on the `#[tokio::main]` block_on thread.
        // Run it on a blocking-permitted thread instead.
        let counts = tokio::task::spawn_blocking(move || {
            flake_info::commands::get_repology_repo_counts(user_agent.as_deref())
        })
        .await
        .context("Repology counts task panicked")??;
        let json = serde_json::to_string(&counts)?;
        match output {
            Some(path) => std::fs::write(path, json)?,
            None => println!("{}", json),
        }
        return Ok(());
    }

    anyhow::ensure!(
        args.elastic.enable || args.elastic.json,
        "at least one of --push or --json must be specified"
    );

    let (exports, ident, partial_error) = run_command(
        args.command,
        args.kind,
        &args.extra,
        args.user_agent.as_deref(),
    )
    .await?;

    if args.elastic.enable {
        if let Err(e) = push_to_elastic(&args.elastic, exports, ident).await {
            match summary {
                Some(mut f) => {
                    write!(f, "Failed to push to Elastic:\n\n```\n{}\n```", e)?;
                    f.flush().unwrap();
                    ()
                }
                None => (),
            }
            return Err(e);
        }
    } else if args.elastic.json {
        println!(
            "{}",
            serde_json::to_string(&collect_exports(exports).await?)?
        );
    }

    // Surface partial failures (e.g. some group members failed to evaluate) as a
    // non-zero exit so CI does not report success while data is missing.
    if let Some(error) = partial_error {
        match summary {
            Some(mut f) => write!(f, "Partial failure:\n\n```\n{}\n```", error)?,
            None => (),
        }
        return Err(error.into());
    }
    Ok(())
}

#[derive(Debug, Error)]
enum FlakeInfoError {
    #[error("Nix check failed: {0}")]
    NixCheck(#[from] NixCheckError),

    #[error("Getting flake info caused an error: {0:?}")]
    Flake(anyhow::Error),
    #[error("Getting nixpkgs info caused an error: {0:?}")]
    Nixpkgs(anyhow::Error),
    #[error("Some members of the group '{0}' could not be processed: \n {}", .1.iter().enumerate().map(|(n, e)| format!("{}: {:?}", n+1, e)).collect::<Vec<String>>().join("\n\n"))]
    Group(String, Vec<anyhow::Error>),
    #[error("Couldn't perform IO: {0}")]
    IO(#[from] io::Error),
}

async fn run_command(
    command: Command,
    kind: Kind,
    extra: &[String],
    user_agent: Option<&str>,
) -> Result<
    (
        LazyExports,
        (String, String, String),
        Option<FlakeInfoError>,
    ),
    FlakeInfoError,
> {
    flake_info::commands::check_nix_version(env!("MIN_NIX_VERSION"))?;

    match command {
        // Handled in main() before the runtime setup below.
        Command::RepologyCounts { .. } => {
            unreachable!("RepologyCounts is handled before run_command")
        }
        Command::Flake { flake, temp_store } => {
            let source = if flake.starts_with("github:") {
                let mut s = flake.split(":").skip(1).next().unwrap().split("/");
                Source::Github {
                    owner: s.next().expect("github owner").to_string(),
                    repo: s.next().expect("github repo").to_string(),
                    git_ref: None,
                    description: None,
                }
            } else {
                Source::Git { url: flake }
            };
            let (info, exports) =
                flake_info::process_flake(&source, &kind, temp_store, extra, false)
                    .map_err(FlakeInfoError::Flake)?;

            let ident = (
                "flake".to_owned(),
                info.name,
                info.revision.unwrap_or("latest".into()),
            );

            Ok((Box::new(|| Ok(exports)), ident, None))
        }
        Command::Nixpkgs {
            channel,
            attribute,
            packages_json_url,
            repology_counts_file,
        } => {
            let nixpkgs = Source::nixpkgs(channel, user_agent)
                .await
                .map_err(FlakeInfoError::Nixpkgs)?;
            let ident = (
                "nixos".to_owned(),
                nixpkgs.channel.to_owned(),
                nixpkgs.git_ref.to_owned(),
            );
            let kind = if attribute.is_some() {
                if !matches!(kind, Kind::All | Kind::Package) {
                    warn!("Forcing --kind package because --attr was specified");
                }
                Kind::Package
            } else {
                kind
            };

            let user_agent = user_agent.map(str::to_owned);

            Ok((
                Box::new(move || {
                    flake_info::process_nixpkgs(
                        &Source::Nixpkgs(nixpkgs),
                        &kind,
                        &attribute,
                        &packages_json_url,
                        &repology_counts_file,
                        &user_agent,
                    )
                    .map_err(FlakeInfoError::Nixpkgs)
                }),
                ident,
                None,
            ))
        }
        Command::NixpkgsArchive {
            source,
            channel,
            attribute,
        } => {
            let ident = (
                "nixos".to_string(),
                channel.to_owned(),
                "latest".to_string(),
            );
            let kind = if attribute.is_some() {
                if !matches!(kind, Kind::All | Kind::Package) {
                    warn!("Forcing --kind package because --attr was specified");
                }
                Kind::Package
            } else {
                kind
            };

            let user_agent = user_agent.map(str::to_owned);

            Ok((
                Box::new(move || {
                    flake_info::process_nixpkgs(
                        &Source::Git { url: source },
                        &kind,
                        &attribute,
                        &None,
                        &None,
                        &user_agent,
                    )
                    .map_err(FlakeInfoError::Nixpkgs)
                }),
                ident,
                None,
            ))
        }
        Command::Group {
            targets,
            temp_store,
            name,
            report,
            with_gc,
        } => {
            // if reporting is enabled delete old report
            if report && tokio::fs::metadata("report.txt").await.is_ok() {
                tokio::fs::remove_file("report.txt").await?;
            }

            let user_agent = user_agent.map(str::to_owned);
            let sources = Source::read_sources_file(&targets)?;
            let (exports_and_hashes, errors) = sources
                .iter()
                .map(|source| match source {
                    Source::Nixpkgs(nixpkgs) => {
                        flake_info::process_nixpkgs(source, &kind, &None, &None, &None, &user_agent)
                            .with_context(|| {
                                format!(
                                    "While processing nixpkgs archive {}",
                                    source.to_flake_ref()
                                )
                            })
                            .map(|result| (result, nixpkgs.git_ref.to_owned()))
                    }
                    _ => flake_info::process_flake(source, &kind, temp_store, &extra, with_gc)
                        .with_context(|| {
                            format!("While processing flake {}", source.to_flake_ref())
                        })
                        .map(|(info, result)| (result, info.revision.unwrap_or("latest".into()))),
                })
                .partition::<Vec<_>, _>(Result::is_ok);

            let (exports, hashes) = exports_and_hashes
                .into_iter()
                .map(|result| result.unwrap()) // each result is_ok
                .fold(
                    (Vec::new(), Vec::new()),
                    |(mut exports, mut hashes), (export, hash)| {
                        exports.extend(export);
                        hashes.push(hash);
                        (exports, hashes)
                    },
                );

            let errors = errors
                .into_iter()
                .map(Result::unwrap_err) // each result is_err
                .collect::<Vec<_>>();

            let partial_error = if !errors.is_empty() {
                let error = FlakeInfoError::Group(name.clone(), errors);
                if exports.is_empty() {
                    return Err(error);
                }

                warn!("=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=");
                warn!("{}", error);
                warn!("=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=");

                if report {
                    let mut file = File::create("report.txt").await?;
                    file.write_all(format!("{}", error).as_bytes()).await?;
                }

                Some(error)
            } else {
                None
            };

            let hash = {
                let mut sha = sha2::Sha256::new();
                for hash in hashes {
                    sha.update(hash);
                }
                format!("{:08x}", sha.finalize())
            };

            let ident = ("group".to_owned(), name, hash);

            Ok((Box::new(|| Ok(exports)), ident, partial_error))
        }
    }
}

async fn push_to_elastic(
    elastic: &ElasticOpts,
    exports: LazyExports,
    ident: (String, String, String),
) -> Result<()> {
    let (index, alias) = elastic
        .elastic_index_name
        .to_owned()
        .map(|ident| {
            (
                format!("{}-{}", elastic.elastic_schema_version.unwrap(), ident),
                None,
            )
        })
        .or_else(|| {
            let (kind, name, hash) = ident;
            let ident = format!(
                "{}-{}-{}-{}",
                kind,
                elastic.elastic_schema_version.unwrap(),
                &name,
                hash
            );
            let alias = format!(
                "latest-{}-{}-{}",
                elastic.elastic_schema_version.unwrap(),
                kind,
                &name
            );

            warn!("Using automatic index identifier: {}", ident);
            Some((ident, Some(alias)))
        })
        .unwrap();

    let es = elastic::Elasticsearch::new(elastic.elastic_url.as_str())?;
    let config = elastic::Config {
        index: &index,
        exists_strategy: elastic.elastic_exists,
    };

    // catch error variant if abort strategy was triggered
    let ensure = es.ensure_index(&config).await;
    if let Err(ElasticsearchError::IndexExistsError(_)) = ensure {
        // The index already exists under the Abort strategy. This is only a
        // legitimate no-op if the alias already points at it (a previous run
        // completed successfully). If the alias does not point here, the index
        // is stale/half-built (e.g. a prior push died before flipping the
        // alias): clear the stranded index before failing so the next run
        // rebuilds from scratch, rather than aborting on the same stale index
        // forever. `alias_points_at` propagates lookup errors and only returns
        // false on a definitive miss, so a transient check failure fails the
        // run without wiping a still-good aliased index.
        match &alias {
            Some(a) if !elastic.no_alias => {
                if es.alias_points_at(a, &index).await? {
                    return Ok(());
                }
                warn!(
                    "index {index} exists but alias {a} does not point at it; \
                     clearing stranded/half-built index so the next run rebuilds"
                );
                if let Err(clear_err) = es.clear_index(&config).await {
                    warn!("failed to clear stranded index {index}: {clear_err}");
                }
                return Err(anyhow!(
                    "Index {index} existed but alias {a} did not point at it \
                     (stale/half-built import); cleared it - failing so the next run rebuilds"
                ));
            }
            _ => return Ok(()),
        }
    } else {
        // throw error if present
        ensure?;
    }

    // From here on this run created the index (Abort or Recreate path). If the
    // push or alias write fails, best-effort delete the just-created index so a
    // partial index is never left stranded for the next run to treat as
    // "already exists". Never clear under Ignore (append): we did not create
    // the index and must not wipe pre-existing data. CI only uses abort
    // (nixpkgs) and recreate (flakes), so Ignore-append is not exercised, but
    // guard it anyway.
    let created_index = !matches!(elastic.elastic_exists, ExistsStrategy::Ignore);

    let successes = collect_exports(exports).await?;

    info!("Pushing to elastic");
    if let Err(e) = es.push_exports(&config, &successes).await {
        if created_index {
            warn!("push failed, clearing partial index {index} so next run rebuilds");
            if let Err(clear_err) = es.clear_index(&config).await {
                warn!("failed to clear partial index {index}: {clear_err}");
            }
        }
        return Err(e).with_context(|| "Failed to push results to elasticsearch".to_string());
    }

    if let Some(alias) = alias {
        if !elastic.no_alias {
            if let Err(e) = es.write_alias(&config, &index, &alias).await {
                if created_index {
                    warn!(
                        "alias write failed, clearing partial index {index} so next run rebuilds"
                    );
                    if let Err(clear_err) = es.clear_index(&config).await {
                        warn!("failed to clear partial index {index}: {clear_err}");
                    }
                }
                return Err(e).with_context(|| "Failed to create alias".to_string());
            }
        } else {
            warn!("Creating alias disabled")
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `--save-summary` writes a markdown file and never touches elasticsearch, so it
    /// must not require `--elastic-schema-version`. This is the invocation shape used
    /// by the `Check Flake Groups` workflow.
    #[test]
    fn save_summary_without_schema_version() {
        let args = Args::from_iter_safe([
            "flake-info",
            "--json",
            "--save-summary",
            "s.md",
            "group",
            "f.toml",
            "name",
            "--report",
            "--with-gc",
        ]);
        assert!(args.is_ok(), "{:?}", args.err());
    }

    /// `--push` does read `elastic_schema_version`, so it keeps demanding one.
    #[test]
    fn push_requires_schema_version() {
        let args = Args::from_iter_safe(["flake-info", "--push", "group", "f.toml", "name"]);
        assert!(args.is_err());
    }

    /// The user-agent override is declared on the top level, so it parses ahead of
    /// any subcommand. The absent case is deliberately not asserted: `FI_USER_AGENT`
    /// may be set in the environment running the tests.
    #[test]
    fn user_agent_override_is_parsed() {
        let args = Args::from_iter_safe([
            "flake-info",
            "--json",
            "--user-agent",
            "custom/1.0",
            "repology-counts",
        ])
        .expect("parses");
        assert_eq!(args.user_agent.as_deref(), Some("custom/1.0"));
    }
}
