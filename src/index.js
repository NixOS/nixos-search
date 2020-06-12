'use strict';

require("./index.scss");

const {Elm} = require('./Main');

Elm.Main.init({
  flags: {
    elasticsearchMappingSchemaVersion: process.env.ELASTICSEARCH_MAPPING_SCHEMA_VERSION || 5,
    elasticsearchUrl: process.env.ELASTICSEARCH_URL || 'https://nixos-search-5886075189.us-east-1.bonsaisearch.net:443',
    elasticsearchUsername : process.env.ELASTICSEARCH_USERNAME || 'z3ZFJ6y2mR',
    elasticsearchPassword : process.env.ELASTICSEARCH_PASSWORD || 'ds8CEvALPf9pui7XG'
  }
});
