use reqwest::{
    header::{HeaderMap, AUTHORIZATION, LINK},
    Url,
};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File},
    io::Write,
    path::PathBuf,
};
use structopt::StructOpt;
use tokio::time::{sleep, Duration};
use toml;

#[derive(StructOpt)]
#[structopt(
    name = "flake-repos",
    about = "Given an input toml, create an output toml of flakes."
)]
struct Opt {
    #[structopt(parse(from_os_str))]
    input_toml_file: PathBuf,

    #[structopt(parse(from_os_str))]
    output_path: PathBuf,

    #[structopt(parse(from_os_str))]
    yaml_file_path: PathBuf,
}

#[derive(Serialize, Deserialize)]
struct Source {
    repo_type: toml::Value,
    owner: serde_json::Value,
    repo: serde_json::Value,
}

async fn get_repos(
    flake_repo: &toml::Value,
    query: &Url,
    headers: &HeaderMap,
    args: &Opt,
) -> Result<(), Box<dyn std::error::Error>> {
    let client = reqwest::Client::builder()
        .user_agent("nixos-search")
        .default_headers(headers.clone())
        .build()?;

    let mut page: u32 = 1;

    let mut another_page = true;

    let mut url = query
        .clone()
        .query_pairs_mut()
        .append_pair("page", &page.to_string())
        .finish()
        .to_string();
    let mut response = client.get(url).send().await?;

    let out_file_path: PathBuf = args
        .output_path
        .join(format!("{}.toml", flake_repo["name"].as_str().unwrap()));

    let mut file = File::create(&out_file_path).expect(
        format!(
            "An error occured in creating file \"{}\"",
            out_file_path.as_path().display().to_string()
        )
        .as_str(),
    );

    loop {
        let result = response.json::<serde_json::Value>().await?;
        let repos = result["items"].as_array().unwrap();

        repos.into_iter().for_each(|repo| {
            let s = Source {
                repo_type: flake_repo["type"].clone(),
                owner: repo["repository"]["owner"]["login"].clone(),
                repo: repo["repository"]["name"].clone(),
            };
            if let Ok(s) = toml::to_string(&s) {
                file.write_fmt(format_args!("[[sources]]\n{}\n", s)).expect(
                    format!("Error in writing to \"{}.toml\"", flake_repo["name"]).as_str(),
                );
            };
        });

        page += 1;
        url = query
            .clone()
            .query_pairs_mut()
            .append_pair("page", &page.to_string())
            .finish()
            .to_string();
        response = client.get(url).send().await?;
        if another_page == false {
            break;
        }
        if let None = response.headers().get(LINK).unwrap().to_str()?.find("next") {
            another_page = false;
        }

        println!("time to sleep");
        sleep(Duration::from_secs(5)).await;
    }

    Ok(())
}

fn update_github_actions_file(
    yaml_file: &PathBuf,
    org_names: &Vec<String>,
) -> Result<(), Box<dyn std::error::Error>> {
    let github_actions_file: String = fs::read_to_string(&yaml_file)?;
    let mut map: serde_yaml::Value = serde_yaml::from_str(&github_actions_file)?;

    map["jobs"]["hourly-import-channel"]["strategy"]["matrix"]["group"] = org_names[..].into();

    fs::write(yaml_file, serde_yaml::to_string(&map).unwrap())?;

    Ok(())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Opt::from_args();

    let input_file = fs::read_to_string(&args.input_toml_file)?;

    let flake_repos: toml::Value = toml::from_str(&input_file.as_str())?;

    let mut query: reqwest::Url;

    let env_github_token = match std::env::var("GITHUB_TOKEN") {
        Ok(env_github_token) => env_github_token,
        Err(e) => panic!("Could not find GITHUB_TOKEN in the environment.\n{:?}", e),
    };

    let mut headers = HeaderMap::new();
    headers.append(
        AUTHORIZATION,
        format!("token {}", env_github_token).parse().unwrap(),
    );

    for repo in flake_repos["sources"].as_array().unwrap() {
        query = Url::parse(format!("https://api.github.com/search/code?q=user:{}+filename:flake.nix+path:/&sort=stars&order=asc&per_page=100", repo["name"]).as_str())?;
        get_repos(&repo, &query, &headers, &args).await?;
    }

    // Get all the "organisation" names to be added to the github action.
    // This is done by getting the file names, without the `.toml` extension,
    // and pushing it into a vector.
    let org_names: Vec<_> = fs::read_dir(&args.output_path)
        .unwrap()
        .map(|f| {
            f.unwrap()
                .path()
                .file_stem()
                .unwrap()
                .to_str()
                .unwrap()
                .to_string()
                .clone()
        })
        .collect();

    update_github_actions_file(&args.yaml_file_path, &org_names)
        .expect("Could not update github actions file");

    Ok(())
}
