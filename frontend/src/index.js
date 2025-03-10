'use strict';

require("./index.scss");
require("elm-keyboard-shortcut")

const {Elm} = require('./Main');

Elm.Main.init({
  flags: {
    elasticsearchMappingSchemaVersion: parseInt(process.env.ELASTICSEARCH_MAPPING_SCHEMA_VERSION),
    elasticsearchUrl: process.env.ELASTICSEARCH_URL || '/backend',
    elasticsearchUsername : process.env.ELASTICSEARCH_USERNAME || 'aWVSALXpZv',
    elasticsearchPassword : process.env.ELASTICSEARCH_PASSWORD || 'X8gPHnzL52wFEekuxsfQ9cSh',
    nixosChannels : JSON.parse(process.env.NIXOS_CHANNELS)
  }
});
