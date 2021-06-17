use anyhow::{Context, Result};
use commands::run_gc;
use flake_info::data::{self, Export, Source};
use flake_info::{commands, elastic};
use log::{debug, error, info, warn};
use std::fs;
use std::path::{Path, PathBuf};
use structopt::{clap::ArgGroup, StructOpt};

#[derive(StructOpt, Debug)]
#[structopt(
    name = "flake-info",
    about = "Extracts various information from a given flake",
    group = ArgGroup::with_name("sources").required(false)
)]
struct Args {
    #[structopt(
        short,
        long,
        help = "Flake identifier passed to nix to gather information about",
        group = "sources"
    )]
    flake: Option<String>,

    #[structopt(help="Extra arguments that are passed to nix as it")]
    extra: Vec<String>,

    #[structopt(
        short,
        long,
        help = "Points to a JSON file containing info targets",
        group = "sources"
    )]
    targets: Option<PathBuf>,

    #[structopt(
        short,
        long,
        help = "Nixpkgs channel to import",
        group = "sources"
    )]
    channel: Option<String>,


    #[structopt(
        short,
        long,
        help = "Kind of data to extract (packages|options|apps|all)",
        default_value
    )]
    kind: data::import::Kind,

    #[structopt(
        long,
        help = "Whether to use a temporary store or not. Located at /tmp/flake-info-store"
    )]
    temp_store: bool,

    #[structopt(
        long,
        help = "Whether to use a temporary store or not. Located at /tmp/flake-info-store"
    )]
    gc: bool,

    #[structopt(flatten)]
    elastic: ElasticOpts,
}
#[derive(StructOpt, Debug)]
struct ElasticOpts {
    #[structopt(
        long = "push",
        help = "Push to Elasticsearch (Configure using FI_ES_* environment variables)"
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
        default_value = "flakes_index"
    )]
    elastic_index_name: String,

    #[structopt(long, help = "Elasticsearch instance url")]
    elastic_recreate_index: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init();

    let args = Args::from_args();

    let sources = match (&args.flake, &args.targets, &args.channel) {
        (Some(ref url), None, None) => vec![data::Source::Git {
            url: url.to_owned(),
        }],
        (None, Some(targets), None) => Source::read_sources_file(targets)?,
        (None, None, Some(channel)) => vec![data::Source::Nixpkgs { channel: channel.to_owned() }],
        (None, None, None) => {
            warn!("No inputs specified!");
            vec![]
        },
        // Any other combination is filtered by clap
        _ => unreachable!(),
    };

    let (successes, errors) = sources
        .iter()
        .map(|source| match source {
            nixpkgs @ Source::Nixpkgs { .. } => flake_info::process_nixpkgs(nixpkgs, &args.kind),
            _ => flake_info::process_flake(source, &args.kind, args.temp_store, &args.extra)
        })
        .partition::<Vec<_>, _>(Result::is_ok);

    let successes = successes
        .into_iter()
        .map(Result::unwrap)
        .flatten()
        .collect::<Vec<_>>();
    let errors = errors
        .into_iter()
        .map(Result::unwrap_err)
        .collect::<Vec<_>>();

    if !errors.is_empty() {
        error!("{} errors occured:", errors.len());
        errors.iter().for_each(|e| {
            error!("{:?}", e);
            debug!("{}", e.backtrace())
        })
    }

    if args.gc {
        run_gc()?
    }

    if args.elastic.enable {
        info!("Pushing to elastic");
        let es = elastic::Elasticsearch::new(args.elastic.elastic_url.as_str())?;
        let config = elastic::Config {
            index: args.elastic.elastic_index_name.as_str(),
            recreate: args.elastic.elastic_recreate_index,
        };

        es.ensure_index(&config).await.with_context(|| {
            format!(
                "Failed to ensure elastic seach index {} exists",
                args.elastic.elastic_index_name
            )
        })?;
        es.push_exports(&config, &successes)
            .await
            .with_context(|| "Failed to push results to elasticsearch".to_string())?
    } else {
        println!("{}", serde_json::to_string(&successes)?);
    }

    Ok(())
}
