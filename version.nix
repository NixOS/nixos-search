{
  /**
    Backend index version used by import jobs when writing data to Elasticsearch
  */
  import = "45";

  /**
    Frontend index version used by the UI when querying Elasticsearch
    Keep this at the old version while 'import' populates a new index, then update to switch traffic
  */
  frontend = "44";
}
