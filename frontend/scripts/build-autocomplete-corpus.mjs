#!/usr/bin/env node
// Mirrors the `autocompleteAssets` derivation in `frontend/default.nix`.
// Writes `src/assets/autocomplete/services-<channel>.json` and
// `hm-<channel>.json` for every channel in `NIXOS_CHANNELS`.
// On any ES failure writes `[]` (matching the Nix fallback) so the dev
// server never blocks on a transient error.

import { writeFileSync, mkdirSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUT_DIR = join(__dirname, "../src/assets/autocomplete");

// Defaults must stay in sync with webpack.dev.js (URL) and webpack.common.js (creds).
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
        console.warn(
            `[autocomplete] ${category}/${channelId}: ${err.message} — writing []`,
        );
        return [];
    }
}

for (const channel of channels) {
    const { id, branch } = channel;
    const [services, hm] = await Promise.all([
        fetchCorpus("services", "service", id, branch),
        fetchCorpus("hm", "home-manager-option", id, branch),
    ]);
    writeFileSync(join(OUT_DIR, `services-${id}.json`), JSON.stringify(services));
    writeFileSync(join(OUT_DIR, `hm-${id}.json`), JSON.stringify(hm));
    console.log(
        `[autocomplete] ${id}: ${services.length} services, ${hm.length} hm options`,
    );
}
