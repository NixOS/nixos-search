pub use elasticsearch::http::transport::Transport;
use elasticsearch::{
    http::response,
    indices::{IndicesCreateParts, IndicesDeleteParts, IndicesExistsParts},
    BulkOperation, Elasticsearch as Client,
};
use lazy_static::lazy_static;
use log::warn;
use serde_json::{json, Value};
use thiserror::Error;

use crate::data::Export;
lazy_static! {
    static ref MAPPING: Value = json!({
        "mappings": {
            "properties": {
                "flake_name": {
                    "type": "text",
                    "analyzer": "english",
                },
                "flake_description": {
                    "type": "text",
                    "analyzer": "english",
                },
                "flake_resolved": {
                    "type": "nested",
                    "properties": {
                        "type": {
                            "type": "keyword"
                        },
                        "owner": {
                            "type": "keyword"
                        },
                        "repo": {
                            "type": "keyword"
                        },
                    }
                },
                "flake_source": {
                    "type": "nested",
                    "properties": {
                        "type": {
                            "type": "keyword"
                        },
                        "owner": {
                            "type": "keyword"
                        },
                        "repo": {
                            "type": "keyword"
                        },
                        "desciption": {
                            "type": "text",
                            "analyzer": "english",
                        },
                        "git_ref": {
                            "type": "keyword"
                        },
                        "url": {
                            "type": "keyword"
                        },
                    }
                },
                "package_attr_name": {
                    "type": "keyword",
                },
                "package_pname": {
                    "type": "keyword",
                },
                "package_pversion": {
                    "type": "keyword"
                },
                "package_platforms": {
                    "type": "keyword"
                },
                "package_outputs": {
                    "type": "keyword"
                },
                "package_description": {
                    "type": "text",
                    "analyzer": "english",
                },
                "package_license": {
                    "type": "nested",
                    "properties": {
                        "license_long": {
                            "type": "text"
                        },
                        "license": {
                            "type": "keyword"
                        },
                        "license_url": {
                            "type": "keyword"
                        }
                    }
                }
            }
        }
    });
}

#[derive(Default)]
pub struct Elasticsearch {
    client: Client,
}

#[derive(Error, Debug)]
pub enum ElasticsearchError {
    #[error("Transport failed to initialize: {0}")]
    TransportInitError(elasticsearch::Error),

    #[error("Failed to send push exports: {0}")]
    PushError(elasticsearch::Error),
    #[error("Push exports returned bad result: {0:?}")]
    PushResponseError(response::Exception),

    #[error("Failed to iitialize index: {0}")]
    InitIndexError(elasticsearch::Error),
    #[error("Push exports returned bad result: {0:?}")]
    InitResponseError(response::Exception),

    #[error("An unexpected error occured in the elastic search client: {0}")]
    ClientError(elasticsearch::Error),

    #[error("Failed to serialize exported data: {0}")]
    SerializationError(#[from] serde_json::Error),
}

impl Elasticsearch {
    pub fn new(url: &str) -> Result<Self, ElasticsearchError> {
        let transport =
            Transport::single_node(url).map_err(ElasticsearchError::TransportInitError)?;
        let client = Client::new(transport);
        Ok(Elasticsearch { client })
    }
    pub fn with_transport(transport: Transport) -> Self {
        let client = Client::new(transport);
        Elasticsearch { client }
    }

    pub async fn push_exports(
        &self,
        config: &Config<'_>,
        exports: &[Export],
    ) -> Result<(), ElasticsearchError> {
        // let exports: Result<Vec<Value>, serde_json::Error> = exports.iter().map(serde_json::to_value).collect();
        // let exports = exports?;
        let body = exports
            .iter()
            .map(|e| BulkOperation::from(BulkOperation::index(e)))
            .collect();

        let response = self
            .client
            .bulk(elasticsearch::BulkParts::Index(config.index))
            .body(body)
            .send()
            .await
            .map_err(ElasticsearchError::PushError)?;

        dbg!(response)
            .exception()
            .await
            .map_err(ElasticsearchError::ClientError)?
            .map(ElasticsearchError::PushResponseError)
            .map_or(Ok(()), Err)
    }

    pub async fn ensure_index(&self, config: &Config<'_>) -> Result<(), ElasticsearchError> {
        let exists = self.check_index(config).await?;

        if exists {
            if config.recreate {
                self.clear_index(config).await?;
            } else {
                warn!("Index \"{}\" exists, not recreating", config.index);
                return Ok(());
            }
        }

        let response = self
            .client
            .indices()
            .create(IndicesCreateParts::Index(config.index))
            .body(MAPPING.as_object())
            .send()
            .await
            .map_err(ElasticsearchError::InitIndexError)?;

        dbg!(response)
            .exception()
            .await
            .map_err(ElasticsearchError::ClientError)?
            .map(ElasticsearchError::PushResponseError)
            .map_or(Ok(()), Err)?;

        Ok(())
    }

    pub async fn check_index(&self, config: &Config<'_>) -> Result<bool, ElasticsearchError> {
        let response = self
            .client
            .indices()
            .exists(IndicesExistsParts::Index(&[config.index]))
            .send()
            .await
            .map_err(ElasticsearchError::InitIndexError)?;

        Ok(response.status_code() == 200)
    }

    pub async fn clear_index(&self, config: &Config<'_>) -> Result<(), ElasticsearchError> {
        let response = self
            .client
            .indices()
            .delete(IndicesDeleteParts::Index(&[config.index]))
            .send()
            .await
            .map_err(ElasticsearchError::InitIndexError)?;

        dbg!(response)
            .exception()
            .await
            .map_err(ElasticsearchError::ClientError)?
            .map(ElasticsearchError::PushResponseError)
            .map_or(Ok(()), Err)
    }
}

pub struct Config<'a> {
    pub index: &'a str,
    pub recreate: bool,
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::*;
    use crate::{
        data::{self, Kind},
        process_flake,
    };

    #[tokio::test]
    async fn test_delete() -> Result<(), Box<dyn std::error::Error>> {
        let es = Elasticsearch::new("http://localhost:9200").unwrap();
        let config = &Config {
            index: "flakes_index",
            recreate: false,
        };
        es.ensure_index(config).await?;
        es.clear_index(config).await?;

        let exists = es.check_index(config).await?;
        assert!(!exists);

        Ok(())
    }

    #[tokio::test]
    async fn test_init() -> Result<(), Box<dyn std::error::Error>> {
        let es = Elasticsearch::new("http://localhost:9200").unwrap();
        let config = &Config {
            index: "flakes_index",
            recreate: true,
        };

        es.ensure_index(config).await?;

        let exists = es.check_index(config).await?;
        assert!(exists, "Index should exist");

        Ok(())
    }

    #[tokio::test]
    async fn test_push() -> Result<(), Box<dyn std::error::Error>> {
        let sources: Vec<data::Source> =
            data::Source::read_sources_file(Path::new("./examples/examples.in.json"))?;

        let exports = sources
            .iter()
            .flat_map(|s| process_flake(s, &Kind::All, false, &[]))
            .flatten()
            .collect::<Vec<Export>>();
        println!("{}", serde_json::to_string(&exports[1]).unwrap());

        let es = Elasticsearch::new("http://localhost:9200").unwrap();
        let config = &Config {
            index: "flakes_index",
            recreate: true,
        };

        es.ensure_index(config).await?;
        es.push_exports(config, &exports).await?;

        Ok(())
    }
}
