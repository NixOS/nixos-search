use std::collections::HashMap;

use clap::arg_enum;
pub use elasticsearch::http::transport::Transport;
use elasticsearch::{BulkOperation, Elasticsearch as Client, http::response, indices::*};
use lazy_static::lazy_static;
use log::{info, warn};
use serde_json::{Value, json};
use thiserror::Error;

use crate::data::Export;
lazy_static! {
    static ref MAPPING: Value = json!({
        "mappings": {
            "properties": {
                "type": {"type": "keyword"},
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
                        "url" : {
                            "type": "keyword"
                        }
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
                    "fields": {
                        "edge": {"type": "text", "analyzer": "edge"},
                        "attr_path": {"type": "text", "analyzer": "attr_path"},
                        "attr_path_reverse": {"type": "text", "analyzer": "attr_path_reverse"}
                    },
                },
                "package_attr_set": {
                    "type": "keyword",
                    "fields": {"edge": {"type": "text", "analyzer": "edge"}},
                },
                "package_pname": {
                    "type": "keyword",
                    "fields": {"edge": {"type": "text", "analyzer": "edge"}},
                },
                "package_pversion": {
                    "type": "keyword"
                },
                "package_platforms": {
                    "type": "keyword"
                },
                "package_system": {
                    "type": "keyword"
                },
                "package_position": {
                    "type": "text"
                },
                "package_outputs": {
                    "type": "keyword"
                },
                "package_default_output": {
                    "type": "keyword"
                },
                "package_programs": {
                    "type": "keyword"
                },
                "package_description": {
                    "type": "text",
                    "analyzer": "english",
                    "fields": {"edge": {"type": "text", "analyzer": "edge"}},
                },
                "package_longDescription": {
                    "type": "text",
                    "analyzer": "english",
                    "fields": {"edge": {"type": "text", "analyzer": "edge"}},
                },
                "package_license": {
                    "type": "nested",
                    "properties": {
                        "fullName": {"type": "text"},
                        "url": {"type": "text"}},
                },
                "package_license_set": {"type": "keyword"},
                "package_maintainers": {
                    "type": "nested",
                    "properties": {
                        "name": {"type": "text"},
                        "email": {"type": "text"},
                        "github": {"type": "text"},
                    },
                },
                "package_maintainers_set": {"type": "keyword"},
                "package_teams": {
                    "type": "nested",
                    "properties": {
                        "members": {
                            "type": "nested",
                            "properties": {
                                "name": {"type": "text"},
                                "email": {"type": "text"},
                                "github": {"type": "text"},
                            },
                        },
                        "githubTeams": {"type": "keyword"},
                    },
                },
                "package_teams_set": {"type": "keyword"},
                "package_homepage": {
                    "type": "keyword"
                },
                // Options fields
                "option_name": {
                    "type": "keyword",
                    "fields": {
                        "edge": {"type": "text", "analyzer": "edge"},
                        "attr_path": {"type": "text", "analyzer": "attr_path"},
                        "attr_path_reverse": {"type": "text", "analyzer": "attr_path_reverse"}
                    },
                },
                "option_description": {
                    "type": "text",
                    "analyzer": "english",
                    "fields": {"edge": {"type": "text", "analyzer": "edge"}},
                },
                "option_type": {"type": "keyword"},
                "option_default": {"type": "text"},
                "option_example": {"type": "text"},
                "option_source": {"type": "keyword"},
            }
        },
        "settings": {
            "analysis": {
                "normalizer": {
                    "lowercase": {"type": "custom", "char_filter": [], "filter": ["lowercase"]}
                },
                "tokenizer": {
                    "edge": {
                        "type": "edge_ngram",
                        "min_gram": 2,
                        "max_gram": 50,
                        "token_chars": [
                            "letter",
                            "digit",
                            "punctuation",
                            "custom",
                        ],
                        // Exclude XML characters < and > from "symbol"
                        "custom_token_chars": "+=~",
                    },
                    "attr_path": {
                        "type": "path_hierarchy",
                        "delimiter": ".",
                    },
                    "attr_path_reverse": {
                        "type": "path_hierarchy",
                        "delimiter": ".",
                        "reverse": true,
                    },
                },
                "analyzer": {
                    "edge": {"tokenizer": "edge", "filter": ["lowercase"]},
                    "attr_path": {"tokenizer": "attr_path", "filter": ["lowercase"]},
                    "attr_path_reverse": {"tokenizer": "attr_path_reverse", "filter": ["lowercase"]},
                    "lowercase": {
                        "type": "custom",
                        "tokenizer": "keyword",
                        "filter": ["lowercase"],
                    },
                },
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
    #[error("One or more bulk requests had failed items")]
    BulkRequestPartialFailure,

    #[error("Failed to iitialize index: {0}")]
    InitIndexError(elasticsearch::Error),
    #[error("Push exports returned bad result: {0:?}")]
    InitResponseError(response::Exception),

    #[error("An unexpected error occured in the elastic search client: {0}")]
    ClientError(elasticsearch::Error),

    #[error("Failed to serialize exported data: {0}")]
    SerializationError(#[from] serde_json::Error),

    #[error("An index with the name \"{0}\" already exists and the (default) stategy is abort")]
    IndexExistsError(String),
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
        let bodies = exports.chunks(10_000).map(|chunk| {
            chunk
                .iter()
                .map(|e| BulkOperation::from(BulkOperation::index(e)))
        });

        let mut had_failures = false;

        for body in bodies {
            let response = self
                .client
                .bulk(elasticsearch::BulkParts::Index(config.index))
                .body(body.collect())
                .send()
                .await
                .map_err(ElasticsearchError::PushError)?;

            let response = dbg!(response);
            if response.status_code().is_client_error() || response.status_code().is_server_error()
            {
                return response
                    .exception()
                    .await
                    .map_err(ElasticsearchError::ClientError)?
                    .map(ElasticsearchError::PushResponseError)
                    .map_or(Ok(()), Err);
            }

            // Elasticsearch bulk API returns HTTP 200 even when some items fail
            // Reference: https://www.elastic.co/guide/en/elasticsearch/reference/current/docs-bulk.html
            let response_body: serde_json::Value = response
                .json()
                .await
                .map_err(ElasticsearchError::ClientError)?;

            // Warn if any items in the bulk request failed
            if let Some(true) = response_body.get("errors").and_then(|v| v.as_bool()) {
                if let Some(items) = response_body.get("items").and_then(|v| v.as_array()) {
                    let mut failed_count = 0;

                    for (idx, item) in items.iter().enumerate() {
                        if let Some(index_result) = item.get("index") {
                            if let Some(status) =
                                index_result.get("status").and_then(|s| s.as_u64())
                            {
                                if status >= 400 {
                                    failed_count += 1;
                                    let error_type = index_result
                                        .get("error")
                                        .and_then(|e| e.get("type"))
                                        .and_then(|t| t.as_str())
                                        .unwrap_or("unknown");
                                    let error_reason = index_result
                                        .get("error")
                                        .and_then(|e| e.get("reason"))
                                        .and_then(|r| r.as_str())
                                        .unwrap_or("");
                                    warn!(
                                        "  Item {}: status {}, type: {}, reason: {}",
                                        idx, status, error_type, error_reason
                                    );
                                }
                            }
                        }
                    }

                    warn!(
                        "Bulk request had {} failed items out of {}",
                        failed_count,
                        items.len()
                    );
                    had_failures = true;
                }
            }
        }

        if had_failures {
            return Err(ElasticsearchError::BulkRequestPartialFailure);
        }

        Ok(())
    }

    pub async fn ensure_index(&self, config: &Config<'_>) -> Result<(), ElasticsearchError> {
        let exists = self.check_index(config).await?;

        if exists {
            match config.exists_strategy {
                ExistsStrategy::Abort => {
                    warn!(
                        "Index \"{}\" already exists, strategy is: Abort push",
                        config.index
                    );
                    return Err(ElasticsearchError::IndexExistsError(
                        config.index.to_owned(),
                    ));
                }
                ExistsStrategy::Ignore => {
                    warn!(
                        "Index \"{}\" already exists, strategy is: Ignore, proceed push",
                        config.index
                    );
                    return Ok(());
                }
                ExistsStrategy::Recreate => {
                    warn!(
                        "Index \"{}\" already exists, strategy is: Recreate index",
                        config.index
                    );
                    self.clear_index(config).await?;
                }
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

    pub async fn write_alias(
        &self,
        _config: &Config<'_>,
        index: &str,
        alias: &str,
    ) -> Result<(), ElasticsearchError> {
        // delete old alias
        info!("Try deleting old alias");
        let response = self
            .client
            .indices()
            .get_alias(IndicesGetAliasParts::Name(&[alias]))
            .send()
            .await
            .map_err(ElasticsearchError::InitIndexError)?;
        let indices = response
            .json::<HashMap<String, Value>>()
            .await
            .map_err(ElasticsearchError::InitIndexError)?
            .keys()
            .cloned()
            .collect::<Vec<String>>();

        self.client
            .indices()
            .delete_alias(IndicesDeleteAliasParts::IndexName(
                &indices.iter().map(AsRef::as_ref).collect::<Vec<_>>(),
                &[alias],
            ))
            .send()
            .await
            .map_err(ElasticsearchError::InitIndexError)?;

        // put new alias
        info!("Putting new alias");
        let response = self
            .client
            .indices()
            .put_alias(IndicesPutAliasParts::IndexName(&[index], alias))
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

#[derive(Debug)]
pub struct Config<'a> {
    pub index: &'a str,
    pub exists_strategy: ExistsStrategy,
}

arg_enum! {
    /// Different strategies to deal with eisting indices
    /// Abort: cancel push, return with an error
    /// Ignore: Reuse existing index, appending new data
    /// Recreate: Drop the existing index and start with a new one
    #[derive(Debug, Clone, Copy)]
    pub enum ExistsStrategy {
        Abort,
        Ignore,
        Recreate,
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::*;
    use crate::{
        data::{self, import::Kind},
        process_flake,
    };

    #[tokio::test]
    async fn test_delete() -> Result<(), Box<dyn std::error::Error>> {
        let es = Elasticsearch::new("http://localhost:9200").unwrap();
        let config = &Config {
            index: "flakes_index",
            exists_strategy: ExistsStrategy::Ignore,
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
            exists_strategy: ExistsStrategy::Recreate,
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
            .map(|(_info, exports)| exports)
            .flatten()
            .collect::<Vec<Export>>();
        println!("{}", serde_json::to_string(&exports[1]).unwrap());

        let es = Elasticsearch::new("http://localhost:9200").unwrap();
        let config = &Config {
            index: "flakes_index",
            exists_strategy: ExistsStrategy::Recreate,
        };

        es.ensure_index(config).await?;
        es.push_exports(config, &exports).await?;

        Ok(())
    }

    #[tokio::test]
    async fn test_abort_if_index_exists() -> Result<(), Box<dyn std::error::Error>> {
        let es = Elasticsearch::new("http://localhost:9200").unwrap();
        let config = &Config {
            index: "flakes_index",
            exists_strategy: ExistsStrategy::Abort,
        };

        es.ensure_index(&Config {
            exists_strategy: ExistsStrategy::Ignore,
            ..*config
        })
        .await?;

        assert!(matches!(
            es.ensure_index(config).await,
            Err(ElasticsearchError::IndexExistsError(_)),
        ));

        es.clear_index(config).await?;

        Ok(())
    }
}
