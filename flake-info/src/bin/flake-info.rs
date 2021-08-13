use anyhow::{Context, Result};
use commands::run_gc;
use flake_info::data::import::{Kind, NixOption};
use flake_info::data::{self, Export, Nixpkgs, Source};
use flake_info::elastic::ExistsStrategy;
use flake_info::{commands, elastic};
use log::{debug, error, info, warn};
use sha2::Digest;
use std::fs;
use std::path::{Path, PathBuf};
use std::ptr::hash;
use structopt::{clap::ArgGroup, StructOpt};
use thiserror::Error;

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
        help = "Kind of data to extract (packages|options|apps|all)",
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
    Flake {
        #[structopt(help = "Flake identifier passed to nix to gather information about")]
        flake: String,

        #[structopt(
            long,
            help = "Whether to use a temporary store or not. Located at /tmp/flake-info-store"
        )]
        temp_store: bool,

        #[structopt(long, help = "Whether to gc the store after info or not")]
        gc: bool,
    },
    Nixpkgs {
        #[structopt(help = "Nixpkgs channel to import")]
        channel: String,
    },
    Group {
        #[structopt(help = "Points to a JSON file containing info targets")]
        targets: PathBuf,

        name: String,

        #[structopt(
            long,
            help = "Whether to use a temporary store or not. Located at /tmp/flake-info-store"
        )]
        temp_store: bool,

        #[structopt(long, help = "Whether to gc the store after info or not")]
        gc: bool,
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

    #[structopt(
        long,
        short = "u",
        env = "FI_ES_USER",
        help = "Elasticsearch username (unimplemented)"
    )]
    elastic_user: Option<String>,

    #[structopt(
        long,
        short = "p",
        env = "FI_ES_PASSWORD",
        help = "Elasticsearch password (unimplemented)"
    )]
    elastic_pw: Option<String>,

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
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init();

    let args = Args::from_args();

    let command_result = run_command(args.command, args.kind, &args.extra).await;

    if let Err(error) = command_result {
        match error {
            FlakeInfoError::Flake(ref e)
            | FlakeInfoError::Nixpkgs(ref e)
            | FlakeInfoError::IO(ref e) => {
                error!("{}", e);
            }
            FlakeInfoError::Group(ref el) => {
                el.iter().for_each(|e| error!("{}", e));
            }
        }

        return Err(error.into());
    }

    let (successes, ident) = command_result.unwrap();

    if args.elastic.enable {
        push_to_elastic(&args.elastic, &successes, ident).await?;
    }

    if args.elastic.json {
        println!("{}", serde_json::to_string(&successes)?);
    }
    Ok(())
}

#[derive(Debug, Error)]
enum FlakeInfoError {
    #[error("Getting flake info caused an error: {0}")]
    Flake(anyhow::Error),
    #[error("Getting nixpkgs info caused an error: {0}")]
    Nixpkgs(anyhow::Error),
    #[error("Getting group info caused one or more errors: {0:?}")]
    Group(Vec<anyhow::Error>),

    #[error("Couldn't perform IO: {0}")]
    IO(anyhow::Error),
}

async fn run_command(
    command: Command,
    kind: Kind,
    extra: &[String],
) -> Result<(Vec<Export>, String), FlakeInfoError> {
    match command {
        Command::Flake {
            flake,
            temp_store,
            gc,
        } => {
            let source = Source::Git { url: flake };
            let exports = flake_info::process_flake(&source, &kind, temp_store, extra)
                .map_err(FlakeInfoError::Flake)?;

            let info = flake_info::get_flake_info(source.to_flake_ref(), temp_store, extra)
                .map_err(FlakeInfoError::Flake)?;

            let ident = format!("{}-{}", info.name, info.revision);

            Ok((exports, ident))
        }
        Command::Nixpkgs { channel } => {
            let nixpkgs = Source::nixpkgs(channel)
                .await
                .map_err(FlakeInfoError::Nixpkgs)?;
            let ident = format!("{}-{}", nixpkgs.channel, nixpkgs.git_ref);
            let exports = flake_info::process_nixpkgs(&Source::Nixpkgs(nixpkgs), &kind)
                .map_err(FlakeInfoError::Nixpkgs)?;

            Ok((exports, ident))
        }
        Command::Group {
            targets,
            temp_store,
            gc,
            name,
        } => {
            let sources = Source::read_sources_file(&targets).map_err(FlakeInfoError::IO)?;
            let (exports_and_hashes, errors) = sources
                .iter()
                .map(|source| match source {
                    Source::Nixpkgs(nixpkgs) => flake_info::process_nixpkgs(source, &kind)
                        .map(|result| (result, nixpkgs.git_ref.to_owned())),
                    _ => flake_info::process_flake(source, &kind, temp_store, &extra).and_then(
                        |result| {
                            flake_info::get_flake_info(source.to_flake_ref(), temp_store, extra)
                                .map(|info| (result, info.revision))
                        },
                    ),
                })
                .partition::<Vec<_>, _>(Result::is_ok);

            let (exports, hashes) = exports_and_hashes
                .into_iter()
                .map(|result| result.unwrap())
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
                .map(Result::unwrap_err)
                .collect::<Vec<_>>();

            if !errors.is_empty() {
                return Err(FlakeInfoError::Group(errors));
            }

            let hash = {
                let mut sha = sha2::Sha256::new();
                for hash in hashes {
                    sha.update(hash);
                }
                format!("{:08x}", sha.finalize())
            };
            Ok((exports, format!("group-{}-{}", name, hash)))
        }
    }
}

async fn push_to_elastic(elastic: &ElasticOpts, successes: &[Export], ident: String) -> Result<()> {
    let index = elastic
        .elastic_index_name
        .as_ref()
        .or_else(|| {
            warn!("Using provided index identifier: {}", ident);
            Some(&ident)
        })
        .map(|ident| format!("{}-{}", elastic.elastic_schema_version.unwrap(), ident))
        .unwrap();

    info!("Pushing to elastic");
    let es = elastic::Elasticsearch::new(elastic.elastic_url.as_str())?;
    let config = elastic::Config {
        index: &index,
        exists_strategy: elastic.elastic_exists,
    };

    es.ensure_index(&config)
        .await
        .with_context(|| format!("Failed to ensure elastic seach index {} exists", index))?;
    es.push_exports(&config, successes)
        .await
        .with_context(|| "Failed to push results to elasticsearch".to_string())?;

    Ok(())
}
