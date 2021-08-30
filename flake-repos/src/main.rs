use octocrab::Octocrab;
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
    repo_type: String,
    owner: String,
    repo: String,
}

async fn get_repos(repo_name: &str, octocrab: &Octocrab, args: &Opt) -> octocrab::Result<()> {
    let mut current_page = octocrab
        .search()
        .code(format!("user:{} filename:flake.nix path:/", &repo_name).as_str())
        .sort("stars")
        .order("asc")
        .page(1u32)
        .per_page(100)
        .send()
        .await?;

    let out_file_path: PathBuf = args.output_path.join(format!("{}.toml", repo_name));

    let mut file = File::create(&out_file_path).expect(
        format!(
            "An error occured in creating file \"{}\"",
            out_file_path.as_path().display().to_string()
        )
        .as_str(),
    );

    loop {
        let mut prs = current_page.take_items();
        println!("Number of items: {}", prs.len());

        for pr in prs.drain(..) {
            let s = Source {
                repo_type: "github".to_string(),
                owner: pr.repository.owner.login,
                repo: pr.repository.name,
            };
            if let Ok(s) = toml::to_string(&s) {
                file.write_fmt(format_args!("[[sources]]\n{}\n", s))
                    .expect(format!("Error in writing to \"{}.toml\"", repo_name).as_str());
            };
        }

        if let Ok(Some(new_page)) = octocrab.get_page(&current_page.next).await {
            current_page = new_page;
        } else {
            break;
        }

        println!("time to sleep");
        sleep(Duration::from_secs(60)).await;
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
async fn main() -> octocrab::Result<()> {
    let args = Opt::from_args();

    let repos = vec!["ngi-nix", "nixos", "nix-community", "tweag"];

    let env_github_token = match std::env::var("GITHUB_TOKEN") {
        Ok(env_github_token) => env_github_token,
        Err(e) => panic!("Could not find GITHUB_TOKEN in the environment.\n{:?}", e),
    };

    let octocrab = octocrab::Octocrab::builder()
        .personal_token(env_github_token)
        .build()?;

    for repo in repos {
        get_repos(repo, &octocrab, &args).await?;
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
