use anyhow::{Context, Result};
use flake_info::commands::NixCheckError;
use flake_info::data::import::Kind;
use flake_info::data::{self, Export, Source};
use flake_info::elastic::{self, ElasticsearchError, ExistsStrategy};
use log::{error, info, warn};
use sha2::Digest;
use std::io;
use std::path::PathBuf;
use structopt::{clap::ArgGroup, StructOpt};
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

type LazyExports = Box<dyn FnOnce() -> Result<Vec<Export>, FlakeInfoError>>;

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init();

    let args = Args::from_args();

    anyhow::ensure!(
        args.elastic.enable || args.elastic.json,
        "at least one of --push or --json must be specified"
    );

    let (exports, ident) = run_command(args.command, args.kind, &args.extra).await?;

    if args.elastic.enable {
        push_to_elastic(&args.elastic, exports, ident).await?;
    } else if args.elastic.json {
        println!("{}", serde_json::to_string(&exports()?)?);
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
) -> Result<(LazyExports, (String, String, String)), FlakeInfoError> {
    flake_info::commands::check_nix_version(env!("MIN_NIX_VERSION"))?;

    match command {
        Command::Flake { flake, temp_store } => {
            let source = Source::Git { url: flake };
            let (info, exports) = flake_info::process_flake(&source, &kind, temp_store, extra)
                .map_err(FlakeInfoError::Flake)?;

            let ident = (
                "flake".to_owned(),
                info.name,
                info.revision.unwrap_or("latest".into()),
            );

            Ok((Box::new(|| Ok(exports)), ident))
        }
        Command::Nixpkgs { channel } => {
            let nixpkgs = Source::nixpkgs(channel)
                .await
                .map_err(FlakeInfoError::Nixpkgs)?;
            let ident = (
                "nixos".to_owned(),
                nixpkgs.channel.to_owned(),
                nixpkgs.git_ref.to_owned(),
            );

            Ok((
                Box::new(move || {
                    flake_info::process_nixpkgs(&Source::Nixpkgs(nixpkgs), &kind)
                        .map_err(FlakeInfoError::Nixpkgs)
                }),
                ident,
            ))
        }
        Command::NixpkgsArchive { source, channel } => {
            let ident = (
                "nixos".to_string(),
                channel.to_owned(),
                "latest".to_string(),
            );

            Ok((
                Box::new(move || {
                    flake_info::process_nixpkgs(&Source::Git { url: source }, &kind)
                        .map_err(FlakeInfoError::Nixpkgs)
                }),
                ident,
            ))
        }
        Command::Group {
            targets,
            temp_store,
            name,
            report,
        } => {
            // if reporting is enabled delete old report
            if report && tokio::fs::metadata("report.txt").await.is_ok() {
                tokio::fs::remove_file("report.txt").await?;
            }

            let sources = Source::read_sources_file(&targets)?;
            let (exports_and_hashes, errors) = sources
                .iter()
                .map(|source| match source {
                    Source::Nixpkgs(nixpkgs) => flake_info::process_nixpkgs(source, &kind)
                        .with_context(|| {
                            format!("While processing nixpkgs archive {}", source.to_flake_ref())
                        })
                        .map(|result| (result, nixpkgs.git_ref.to_owned())),
                    _ => flake_info::process_flake(source, &kind, temp_store, &extra)
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

            if !errors.is_empty() {
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
            }

            let hash = {
                let mut sha = sha2::Sha256::new();
                for hash in hashes {
                    sha.update(hash);
                }
                format!("{:08x}", sha.finalize())
            };

            let ident = ("group".to_owned(), name, hash);

            Ok((Box::new(|| Ok(exports)), ident))
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
        // abort on abort
        return Ok(());
    } else {
        // throw error if present
        ensure?;
    }

    let successes = exports()?;

    info!("Pushing to elastic");
    es.push_exports(&config, &successes)
        .await
        .with_context(|| "Failed to push results to elasticsearch".to_string())?;

    if let Some(alias) = alias {
        if !elastic.no_alias {
            es.write_alias(&config, &index, &alias)
                .await
                .with_context(|| "Failed to create alias".to_string())?;
        } else {
            warn!("Creating alias disabled")
        }
    }

    Ok(())
}
