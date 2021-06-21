use elasticsearch::{IndexParts, indices::IndicesExistsParts};



#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {

    check_index().await?;


    Ok(())
}


async fn check_index() -> Result<(),Box<dyn std::error::Error> > {

    let client = elasticsearch::Elasticsearch::new(elasticsearch::http::transport::Transport::single_node("https://kog80y7vrg:myuaqqcb4r@nixos-search-5886075189.us-east-1.bonsaisearch.net:44")?);

    let result = client
            .index(IndexParts::Index("latest-21-21.05"))
            .send()
            .await?;
            Ok(())
}
