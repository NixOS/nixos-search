"use strict";

require("./index.scss");
require("elm-keyboard-shortcut");

const { Elm } = require("./Main");

// Honor the user's data-saver preference so the typeahead can disable
// itself on metered or slow connections. Falsy default for browsers
// without the Network Information API.
const saveData = Boolean(
    typeof navigator !== "undefined" &&
        navigator.connection &&
        (navigator.connection.saveData ||
            ["slow-2g", "2g"].includes(navigator.connection.effectiveType)),
);

Elm.Main.init({
    flags: {
        elasticsearchMappingSchemaVersion: parseInt(
            process.env.ELASTICSEARCH_MAPPING_SCHEMA_VERSION,
        ),
        elasticsearchUrl: process.env.ELASTICSEARCH_URL || "/backend",
        elasticsearchUsername:
            process.env.ELASTICSEARCH_USERNAME || "aWVSALXpZv",
        elasticsearchPassword:
            process.env.ELASTICSEARCH_PASSWORD || "X8gPHnzL52wFEekuxsfQ9cSh",
        nixosChannels: JSON.parse(process.env.NIXOS_CHANNELS),
        saveData: saveData,
    },
});

document.addEventListener("DOMContentLoaded", function () {
    const shortcutEl = document.getElementById("shortcut-list-el");
    const searchInput = document.getElementById("search-query-input");
    // the shortcutEl is only used for focusing the search input.
    // disable it when the search input is focused so we can type normally.
    if (shortcutEl && searchInput) {
        searchInput.addEventListener("focus", () => {
            shortcutEl.disconnectedCallback();
        });
        searchInput.addEventListener("blur", () => {
            shortcutEl.connectedCallback();
        });
    }
});
