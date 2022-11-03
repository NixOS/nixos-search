'use strict';

require("./index.scss");

const {Elm} = require('./Main');

Elm.Main.init({
  flags: {
    elasticsearchMappingSchemaVersion: parseInt(process.env.ELASTICSEARCH_MAPPING_SCHEMA_VERSION),
    elasticsearchUrl: process.env.ELASTICSEARCH_URL || 'https://nixos-search-7-1733963800.us-east-1.bonsaisearch.net:443',
    elasticsearchUsername : process.env.ELASTICSEARCH_USERNAME || 'aWVSALXpZv',
    elasticsearchPassword : process.env.ELASTICSEARCH_PASSWORD || 'X8gPHnzL52wFEekuxsfQ9cSh',
    nixosChannels : JSON.parse(process.env.NIXOS_CHANNELS)
  }
});
