#!/usr/bin/env node
// Pre-generates the typeahead corpus fetched from Elasticsearch. Writes
// `<AUTOCOMPLETE_OUT_DIR>/modular_service-<channel>.json` and
// `home_manager-<channel>.json` for every channel in `NIXOS_CHANNELS`
// (default output dir: `public/autocomplete`).
//
// Invoked in two places:
//   - the `dev` npm script, before the rsbuild dev server starts, and
//   - the `Build autocomplete corpus` CI step, after `nix build .#frontend`,
//     writing into `./dist/autocomplete` before the Netlify deploy.
//
// The Nix build itself does not run this (the sandbox has no network); the
// CI step does. On any ES failure it writes `[]` so neither the dev server
// nor the deploy blocks on a transient error.

import { writeFileSync, mkdirSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUT_DIR =
    process.env.AUTOCOMPLETE_OUT_DIR ||
    join(__dirname, "../public/autocomplete");

// Defaults must stay in sync with the ES URL and credentials in
// `rsbuild.config.mjs` (`server.proxy` target and `source.define`).
const ELASTICSEARCH_URL =
    process.env.ELASTICSEARCH_URL ||
    "https://nixos-search-7-1733963800.us-east-1.bonsaisearch.net";
const ELASTICSEARCH_MAPPING_SCHEMA_VERSION =
    process.env.ELASTICSEARCH_MAPPING_SCHEMA_VERSION || "0";
const ELASTICSEARCH_USERNAME =
    process.env.ELASTICSEARCH_USERNAME || "aWVSALXpZv";
const ELASTICSEARCH_PASSWORD =
    process.env.ELASTICSEARCH_PASSWORD || "X8gPHnzL52wFEekuxsfQ9cSh";
const NIXOS_CHANNELS_RAW = process.env.NIXOS_CHANNELS;

if (!NIXOS_CHANNELS_RAW) {
    console.error("NIXOS_CHANNELS env var is required");
    process.exit(1);
}

const parsed = JSON.parse(NIXOS_CHANNELS_RAW);
const channels = Array.isArray(parsed) ? parsed : parsed.channels;
mkdirSync(OUT_DIR, { recursive: true });

const authHeader =
    ELASTICSEARCH_USERNAME || ELASTICSEARCH_PASSWORD
        ? "Basic " +
          Buffer.from(
              `${ELASTICSEARCH_USERNAME}:${ELASTICSEARCH_PASSWORD}`,
          ).toString("base64")
        : null;

let hadFailure = false;

async function fetchCorpus(category, docType, channelId, branch) {
    const index = `latest-${ELASTICSEARCH_MAPPING_SCHEMA_VERSION}-${branch}`;
    const url = `${ELASTICSEARCH_URL}/${index}/_search`;
    const body = JSON.stringify({
        from: 0,
        size: 10000,
        _source: ["option_name"],
        query: { bool: { filter: [{ term: { type: docType } }] } },
    });

    try {
        const headers = { "Content-Type": "application/json" };
        if (authHeader) headers["Authorization"] = authHeader;
        const res = await fetch(url, { method: "POST", headers, body });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const json = await res.json();
        const items = (json?.hits?.hits ?? []).map((h) => ({
            name: h._source.option_name,
        }));
        return items;
    } catch (err) {
        hadFailure = true;
        console.warn(
            `[autocomplete] ${category}/${channelId}: ${err.message} — writing []`,
        );
        return [];
    }
}

for (const channel of channels) {
    const { id, branch } = channel;
    const [services, hm] = await Promise.all([
        fetchCorpus("modular_service", "service", id, branch),
        fetchCorpus("home_manager", "home-manager-option", id, branch),
    ]);
    writeFileSync(join(OUT_DIR, `modular_service-${id}.json`), JSON.stringify(services));
    writeFileSync(join(OUT_DIR, `home_manager-${id}.json`), JSON.stringify(hm));
    console.log(
        `[autocomplete] ${id}: ${services.length} modular_service, ${hm.length} home_manager options`,
    );
}

if (hadFailure) {
    console.error("[autocomplete] one or more fetches failed — corpus may be incomplete");
    if (process.env.CI) {
        process.exit(1);
    }
}
