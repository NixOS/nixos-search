{
  # Backend index version used by import jobs when writing data to Elasticsearch.
  #
  # When making backwards-incompatible schema changes,
  # change the code for the import job first, updating this version number.
  # Only after the new index has been populated, update the frontend.
  import = "50";

  # Frontend index version used by the UI when querying Elasticsearch
  # Keep this at the old version while 'import' populates a new index, then update to switch traffic
  frontend = "50";
}
