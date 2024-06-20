'use strict';

require("./index.scss");
require("elm-keyboard-shortcut")

const {Elm} = require('./Main');

const app = Elm.Main.init({
  flags: {
    elasticsearchMappingSchemaVersion: parseInt(process.env.ELASTICSEARCH_MAPPING_SCHEMA_VERSION),
    elasticsearchUrl: process.env.ELASTICSEARCH_URL || '/backend',
    elasticsearchUsername : process.env.ELASTICSEARCH_USERNAME || 'aWVSALXpZv',
    elasticsearchPassword : process.env.ELASTICSEARCH_PASSWORD || 'X8gPHnzL52wFEekuxsfQ9cSh',
    nixosChannels : JSON.parse(process.env.NIXOS_CHANNELS)
  }
});

app.ports.copyToClipboard.subscribe(fallbackCopyTextToClipboard)

function fallbackCopyTextToClipboard(text) {
  var textArea = document.createElement('textarea')
  textArea.value = text

  // avoid scrolling to bottom
  textArea.style.top = '0'
  textArea.style.left = '0'
  textArea.style.position = 'fixed'

  document.body.appendChild(textArea)
  textArea.focus()
  textArea.select()

  try {
    return document.execCommand('copy')
  } catch(err) {
    console.error('fallback: oops, unable to copy', err)
    return false
  } finally {
    document.body.removeChild(textArea)
  }
}
