use octocrab::Octocrab;
use serde::{Deserialize, Serialize};
use std::{fs::File, io::Write};
use tokio::time::{sleep, Duration};
use toml;

#[derive(Serialize, Deserialize)]
struct Source {
    repo_type: String,
    owner: String,
    repo: String,
}

async fn get_repos(repo_name: &str, octocrab: &Octocrab) -> octocrab::Result<()> {
    let mut current_page = octocrab
        .search()
        .code(format!("user:{} filename:flake.nix path:/", &repo_name).as_str())
        .sort("stars")
        .order("asc")
        .page(1u32)
        .per_page(100)
        .send()
        .await?;

    let mut file = File::create(format!("../flakes/{}.toml", repo_name))
        .expect(format!("An error occured in creating file \"{}.toml\"", repo_name).as_str());

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

#[tokio::main]
async fn main() -> octocrab::Result<()> {
    let octocrab = octocrab::Octocrab::builder()
        .personal_token(std::env::var("GITHUB_TOKEN").unwrap())
        .build()?;
    let repos = vec!["ngi-nix", "nixos", "nix-community", "tweag"];

    for repo in repos {
        get_repos(repo, &octocrab).await?;
    }

    Ok(())
}
