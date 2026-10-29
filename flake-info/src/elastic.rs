use std::collections::{HashMap, HashSet};

use clap::arg_enum;
pub use elasticsearch::http::transport::Transport;
use elasticsearch::{
    BulkOperation, Elasticsearch as Client, MgetParts,
    http::{StatusCode, response},
    indices::*,
};
use lazy_static::lazy_static;
use log::{info, warn};
use serde::Serialize;
use serde_json::{Value, json};
use thiserror::Error;

use crate::data::Export;

/// The maximum number of documents in one bulk request.
const BULK_MAX_DOCS: usize = 7_000;

/// The maximum size in bytes of the documents in one bulk request.
/// Elasticsearch refuses a request that is larger than its
/// `http.max_content_length` (100 MiB by default) with a 413 status, and the
/// proxy in front of the cluster stops a slow request with a 504 status. The
/// document count limit alone does not prevent this: icon and screenshot
/// documents each contain a base64 image, and 7,000 of them are larger than
/// 100 MiB.
const BULK_MAX_BYTES: usize = 10 * 1024 * 1024;

/// The maximum number of ids in one multi get request.
const MGET_MAX_IDS: usize = 10_000;

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
                    "type": "keyword",
                    "normalizer": "lowercase",
                    "fields": {"edge": {"type": "text", "analyzer": "edge"}},
                },
                "package_mainProgram": {
                    "type": "keyword",
                    "normalizer": "lowercase",
                    "fields": {"edge": {"type": "text", "analyzer": "edge"}},
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
                        "shortName": {"type": "text"},
                        "spdxId": {"type": "text"},
                        "url": {"type": "text"}},
                },
                "package_license_set": {"type": "keyword"},
                "package_license_expression": {"type": "object", "enabled": false},
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
                "package_modular_services": {
                    "type": "keyword"
                },
                // Rendered, never queried: the entry's own fields are searched
                // through the flattened sets below.
                "package_desktop_entries": {"type": "object", "enabled": false},
                // File names of the images, which are `icon` documents in the
                // shared image index. Rendered, never queried.
                "package_desktop_icons": {"type": "object", "enabled": false},
                "package_categories_set": {"type": "keyword"},
                "package_mime_types_set": {"type": "keyword"},
                "package_component_ids": {"type": "keyword"},
                "package_screenshots": {"type": "object", "enabled": false},
                "package_dep_count": {
                    "type": "rank_feature"
                },
                "package_repology_repos": {
                    "type": "rank_feature"
                },
                // Icon fields
                "icon_file": {"type": "keyword"},
                // A base64 image, read once per frontend build and written out
                // as a static file. Indexing it would be pure cost.
                "icon_data": {"type": "text", "index": false},
                // Screenshot fields, which an icon's are the pattern for
                "screenshot_file": {"type": "keyword"},
                "screenshot_data": {"type": "text", "index": false},
                // Localization fields
                "localization_locale": {"type": "keyword"},
                // Arbitrary strings as keys, read once per frontend build and
                // written out as a static file. Never queried.
                "localization_strings": {"type": "object", "enabled": false},
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
                // Modular service fields
                "service_package": {
                    "type": "keyword",
                    "fields": {
                        "edge": {"type": "text", "analyzer": "edge"}
                    },
                },
                "service_module": {"type": "keyword"},
                "service_packages": {
                    "type": "keyword",
                    "fields": {
                        "edge": {"type": "text", "analyzer": "edge"}
                    },
                },
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
    #[error("Elasticsearch returned HTTP {status}: {body}")]
    HttpStatusError { status: StatusCode, body: String },

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

    #[error("Elasticsearch returned no UUID for the index \"{0}\"")]
    IndexUuidMissingError(String),
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
        self.push_bulk(config.index, exports, |_| None).await
    }

    /// Push the image documents `images` into the shared image index `index`,
    /// and create the index with the alias `alias` if it does not exist. The
    /// index must have an alias, because the weekly prune deletes all indices
    /// that do not have an alias. All imports of one schema
    /// version share this index, thus Elasticsearch keeps each image one time
    /// and not one time for each channel and revision. An image id identifies
    /// the same image always (see `Export::image_id`), thus this function
    /// pushes only the images that the index does not contain.
    pub async fn push_images(
        &self,
        index: &str,
        alias: &str,
        images: &[Export],
    ) -> Result<(), ElasticsearchError> {
        self.ensure_shared_index(index, alias).await?;

        let mut seen = HashSet::new();
        let mut ids = Vec::new();
        for image in images {
            if let Some(id) = image.image_id() {
                if seen.insert(id.clone()) {
                    ids.push((id, image));
                }
            }
        }
        let present = self
            .present_ids(index, ids.iter().map(|(id, _)| id.as_str()))
            .await?;
        let missing: Vec<&Export> = ids
            .iter()
            .filter(|(id, _)| !present.contains(id))
            .map(|(_, image)| *image)
            .collect();
        info!(
            "{} of {} images are not in index {}",
            missing.len(),
            ids.len(),
            index
        );

        self.push_bulk(index, &missing, |image| image.image_id())
            .await
    }

    /// Create the index `index` with the alias `alias` if the index does not
    /// exist. Imports that run at the same time can try to create the same
    /// index. The create request adds the alias, thus if the request fails,
    /// the index is correct if it exists after the failure.
    async fn ensure_shared_index(
        &self,
        index: &str,
        alias: &str,
    ) -> Result<(), ElasticsearchError> {
        let config = Config {
            index,
            exists_strategy: ExistsStrategy::Ignore,
        };
        if self.check_index(&config).await? {
            return Ok(());
        }

        let mut body = MAPPING.clone();
        body["aliases"][alias] = json!({});
        let response = self
            .client
            .indices()
            .create(IndicesCreateParts::Index(index))
            .body(body)
            .send()
            .await
            .map_err(ElasticsearchError::InitIndexError)?;
        if let Err(e) = check_response(response).await {
            if !self.check_index(&config).await? {
                return Err(e);
            }
        }
        Ok(())
    }

    /// Return the ids in `ids` that the index `index` contains.
    async fn present_ids<'a>(
        &self,
        index: &str,
        ids: impl Iterator<Item = &'a str>,
    ) -> Result<HashSet<String>, ElasticsearchError> {
        let ids: Vec<&str> = ids.collect();
        let mut present = HashSet::new();
        for chunk in ids.chunks(MGET_MAX_IDS) {
            let response = self
                .client
                .mget(MgetParts::Index(index))
                ._source(&["false"])
                .body(json!({ "ids": chunk }))
                .send()
                .await
                .map_err(ElasticsearchError::ClientError)?;
            let body: Value = check_response(response)
                .await?
                .json()
                .await
                .map_err(ElasticsearchError::ClientError)?;
            present.extend(found_ids(&body));
        }
        Ok(present)
    }

    /// Push `docs` into the index `index`. If `id` gives an id for a document,
    /// the document gets that id. Otherwise Elasticsearch makes an id.
    async fn push_bulk<T: Serialize>(
        &self,
        index: &str,
        docs: &[T],
        id: impl Fn(&T) -> Option<String>,
    ) -> Result<(), ElasticsearchError> {
        let chunks = bulk_chunks(docs, BULK_MAX_DOCS, BULK_MAX_BYTES)?;
        info!(
            "Pushing {} documents to {} in {} bulk requests",
            docs.len(),
            index,
            chunks.len()
        );

        let mut had_failures = false;

        for chunk in chunks {
            let body = chunk
                .iter()
                .map(|doc| {
                    let operation = BulkOperation::index(doc);
                    BulkOperation::from(match id(doc) {
                        Some(id) => operation.id(id),
                        None => operation,
                    })
                })
                .collect();

            let response = self
                .client
                .bulk(elasticsearch::BulkParts::Index(index))
                .body(body)
                .send()
                .await
                .map_err(ElasticsearchError::PushError)?;
            let response = check_response(response).await?;

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

    /// Look up whether the alias currently resolves to (among others) `index`.
    /// Thin wrapper over the `get_alias` call used by `write_alias`.
    pub async fn alias_points_at(
        &self,
        alias: &str,
        index: &str,
    ) -> Result<bool, ElasticsearchError> {
        let response = self
            .client
            .indices()
            .get_alias(IndicesGetAliasParts::Name(&[alias]))
            .send()
            .await
            .map_err(ElasticsearchError::InitIndexError)?;

        if response.status_code() == 404 {
            return Ok(false);
        }

        let indices = response
            .json::<HashMap<String, Value>>()
            .await
            .map_err(ElasticsearchError::InitIndexError)?;

        Ok(indices.contains_key(index))
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

        check_response(response).await?;

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

    /// Return the UUID of the index `index`. Elasticsearch gives a new UUID
    /// to each index that it creates, also to an index that has the name of
    /// an index that it deleted. Thus a different UUID shows that the index
    /// was deleted and created again.
    pub async fn index_uuid(&self, index: &str) -> Result<String, ElasticsearchError> {
        let response = self
            .client
            .indices()
            .get_settings(IndicesGetSettingsParts::IndexName(
                &[index],
                &["index.uuid"],
            ))
            .send()
            .await
            .map_err(ElasticsearchError::InitIndexError)?;
        let body: Value = check_response(response)
            .await?
            .json()
            .await
            .map_err(ElasticsearchError::InitIndexError)?;
        body[index]["settings"]["index"]["uuid"]
            .as_str()
            .map(str::to_owned)
            .ok_or_else(|| ElasticsearchError::IndexUuidMissingError(index.to_owned()))
    }

    pub async fn clear_index(&self, config: &Config<'_>) -> Result<(), ElasticsearchError> {
        let response = self
            .client
            .indices()
            .delete(IndicesDeleteParts::Index(&[config.index]))
            .send()
            .await
            .map_err(ElasticsearchError::InitIndexError)?;

        check_response(response).await?;
        Ok(())
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

        check_response(response).await?;
        Ok(())
    }
}

/// Return `response` if its status is not an error. Otherwise return the error.
/// A proxy in front of Elasticsearch can send an error that is not an
/// Elasticsearch exception, for example a 413 or a 504 status with an empty
/// body. For such an error, the result contains the status and the start of
/// the body.
async fn check_response(
    response: response::Response,
) -> Result<response::Response, ElasticsearchError> {
    let status = response.status_code();
    if !(status.is_client_error() || status.is_server_error()) {
        return Ok(response);
    }
    let body = response
        .text()
        .await
        .map_err(ElasticsearchError::ClientError)?;
    Err(match serde_json::from_str::<response::Exception>(&body) {
        Ok(exception) => ElasticsearchError::PushResponseError(exception),
        Err(_) => ElasticsearchError::HttpStatusError {
            status,
            body: body.chars().take(200).collect(),
        },
    })
}

/// Return the ids of the documents that a multi get response `body` found.
fn found_ids(body: &Value) -> impl Iterator<Item = String> + '_ {
    body["docs"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|doc| doc["found"].as_bool() == Some(true))
        .filter_map(|doc| doc["_id"].as_str().map(str::to_owned))
}

/// Divide `docs` into chunks of at most `max_docs` documents and at most
/// `max_bytes` bytes of serialized JSON. A document that is larger than
/// `max_bytes` goes into a chunk alone.
fn bulk_chunks<T: Serialize>(
    docs: &[T],
    max_docs: usize,
    max_bytes: usize,
) -> Result<Vec<&[T]>, serde_json::Error> {
    let mut chunks = Vec::new();
    let mut start = 0;
    let mut bytes = 0;
    for (i, doc) in docs.iter().enumerate() {
        let size = serde_json::to_vec(doc)?.len();
        if i > start && (i - start == max_docs || bytes + size > max_bytes) {
            chunks.push(&docs[start..i]);
            start = i;
            bytes = 0;
        }
        bytes += size;
    }
    if start < docs.len() {
        chunks.push(&docs[start..]);
    }
    Ok(chunks)
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

    #[test]
    fn test_bulk_chunks_by_count() {
        let docs = vec![1u8; 7];
        let chunks = bulk_chunks(&docs, 3, usize::MAX).unwrap();
        let lens: Vec<usize> = chunks.iter().map(|c| c.len()).collect();
        assert_eq!(lens, vec![3, 3, 1]);
    }

    #[test]
    fn test_bulk_chunks_by_bytes() {
        // Each string serializes to 10 bytes: 8 characters and 2 quotes.
        let docs = vec!["x".repeat(8); 5];
        let chunks = bulk_chunks(&docs, usize::MAX, 25).unwrap();
        let lens: Vec<usize> = chunks.iter().map(|c| c.len()).collect();
        assert_eq!(lens, vec![2, 2, 1]);
    }

    #[test]
    fn test_bulk_chunks_oversized_doc_alone() {
        let docs = vec!["a".to_string(), "x".repeat(100), "b".to_string()];
        let chunks = bulk_chunks(&docs, usize::MAX, 10).unwrap();
        let lens: Vec<usize> = chunks.iter().map(|c| c.len()).collect();
        assert_eq!(lens, vec![1, 1, 1]);
    }

    #[test]
    fn test_found_ids() {
        let body = json!({"docs": [
            {"_index": "images-1", "_id": "icon-a.png", "found": true},
            {"_index": "images-1", "_id": "icon-b.png", "found": false},
            {"_index": "images-1", "_id": "screenshot-c.webp", "found": true},
        ]});
        assert_eq!(
            found_ids(&body).collect::<Vec<_>>(),
            ["icon-a.png", "screenshot-c.webp"]
        );
        assert_eq!(found_ids(&json!({})).count(), 0);
    }

    #[test]
    fn test_bulk_chunks_empty() {
        let docs: Vec<u8> = Vec::new();
        assert!(bulk_chunks(&docs, 3, 10).unwrap().is_empty());
    }

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
            .flat_map(|s| process_flake(s, &Kind::All, false, &[], false))
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
    async fn test_alias_points_at() -> Result<(), Box<dyn std::error::Error>> {
        let es = Elasticsearch::new("http://localhost:9200").unwrap();
        let alias = "test_alias_points_at";

        let config_a = &Config {
            index: "test_alias_points_at_a",
            exists_strategy: ExistsStrategy::Recreate,
        };
        let config_b = &Config {
            index: "test_alias_points_at_b",
            exists_strategy: ExistsStrategy::Recreate,
        };

        es.ensure_index(config_a).await?;
        es.ensure_index(config_b).await?;

        // Alias points at index A.
        es.write_alias(config_a, config_a.index, alias).await?;
        assert!(es.alias_points_at(alias, config_a.index).await?);
        assert!(!es.alias_points_at(alias, config_b.index).await?);

        // Flip the alias to index B.
        es.write_alias(config_b, config_b.index, alias).await?;
        assert!(es.alias_points_at(alias, config_b.index).await?);
        assert!(!es.alias_points_at(alias, config_a.index).await?);

        es.clear_index(config_a).await?;
        es.clear_index(config_b).await?;

        Ok(())
    }

    #[tokio::test]
    async fn test_index_uuid() -> Result<(), Box<dyn std::error::Error>> {
        let es = Elasticsearch::new("http://localhost:9200").unwrap();
        let config = &Config {
            index: "test_index_uuid",
            exists_strategy: ExistsStrategy::Recreate,
        };

        es.ensure_index(config).await?;
        let uuid = es.index_uuid(config.index).await?;
        assert_eq!(uuid, es.index_uuid(config.index).await?);

        // Create the index again with the same name.
        es.ensure_index(config).await?;
        assert_ne!(uuid, es.index_uuid(config.index).await?);

        es.clear_index(config).await?;
        assert!(es.index_uuid(config.index).await.is_err());

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
