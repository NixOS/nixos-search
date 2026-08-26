#!/usr/bin/env node
// Writes the desktop entry icons out of Elasticsearch as static files, one per
// `icon` document, named after the image so that `<img src>` in a result card
// has something to point at. Writes `<ICONS_OUT_DIR>/<icon_file>` for every
// channel in `NIXOS_CHANNELS` (default output dir: `public/icons`).
//
// Invoked in two places, following `build-autocomplete-corpus.mjs`:
//   - the `dev` npm script, before the rsbuild dev server starts, and
//   - the `Build icon assets` CI step, after `nix build .#frontend`, writing
//     into `./dist/icons` before the Netlify deploy.
//
// The Nix build itself does not run this (the sandbox has no network); the CI
// step does. Icons a deploy did not write render as nothing rather than as a
// broken image, so neither the dev server nor the deploy blocks on a transient
// error.
//
// An image's name is derived from its contents, so it is the same file across
// channels and across imports. That makes the pooled output deduplicated, and
// makes each file safe to cache indefinitely.

import { writeFileSync, mkdirSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUT_DIR = process.env.ICONS_OUT_DIR || join(__dirname, "../public/icons");

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

// Icons run to a few thousand per channel, past the 10000 `from + size` ceiling
// once channels are pooled, so pages are walked with `search_after` over
// `icon_file` rather than by offset.
const PAGE_SIZE = 1000;

// A name reaches this script over the network and is then used as a path, so it
// is checked against the shape `flake-info` gives it rather than trusted to
// stay inside the output directory.
const ICON_FILE = /^[0-9a-f]{32}\.[a-z]+$/;

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

async function fetchPage(branch, searchAfter) {
    const index = `latest-${ELASTICSEARCH_MAPPING_SCHEMA_VERSION}-${branch}`;
    const url = `${ELASTICSEARCH_URL}/${index}/_search`;
    const body = JSON.stringify({
        size: PAGE_SIZE,
        _source: ["icon_file", "icon_data"],
        // An index written before this schema knew about icons has no mapping
        // for the sort field, which is an error rather than an empty result
        // unless `unmapped_type` says what to assume. That index is the normal
        // state while `import` runs ahead of `frontend`, so it has to read as
        // "no icons yet" and leave a real outage to stand out.
        sort: [{ icon_file: { order: "asc", unmapped_type: "keyword" } }],
        query: { bool: { filter: [{ term: { type: "icon" } }] } },
        ...(searchAfter ? { search_after: searchAfter } : {}),
    });

    const headers = { "Content-Type": "application/json" };
    if (authHeader) headers["Authorization"] = authHeader;
    const res = await fetch(url, { method: "POST", headers, body });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return (await res.json())?.hits?.hits ?? [];
}

// Pooled across channels: the same image keeps the same name in each, so a
// channel that shares an icon with one already written costs nothing.
const written = new Set();

for (const channel of channels) {
    const { id, branch } = channel;
    let searchAfter = null;
    let count = 0;

    try {
        for (;;) {
            const hits = await fetchPage(branch, searchAfter);
            if (hits.length === 0) break;
            for (const hit of hits) {
                const { icon_file, icon_data } = hit._source;
                count += 1;
                if (!ICON_FILE.test(icon_file)) {
                    throw new Error(`unexpected icon name ${icon_file}`);
                }
                if (written.has(icon_file)) continue;
                // The image is base64 only because the document holding it is
                // JSON; the name says what format the bytes are in.
                writeFileSync(
                    join(OUT_DIR, icon_file),
                    Buffer.from(icon_data, "base64"),
                );
                written.add(icon_file);
            }
            if (hits.length < PAGE_SIZE) break;
            searchAfter = hits[hits.length - 1].sort;
        }
    } catch (err) {
        hadFailure = true;
        console.warn(`[icons] ${id}: ${err.message} — skipping the rest`);
    }

    console.log(`[icons] ${id}: ${count} icons`);
}

console.log(`[icons] ${written.size} distinct icons written to ${OUT_DIR}`);

if (hadFailure) {
    console.error("[icons] one or more fetches failed — icons may be missing");
    if (process.env.CI) {
        process.exit(1);
    }
}
