#!/usr/bin/env node
// Writes the desktop entries' translations out of Elasticsearch as static
// files, one per locale, so that a visitor who asks for a language fetches it
// once for the whole corpus. Writes `<LOCALES_OUT_DIR>/<tag>.json` for every
// locale in `NIXOS_CHANNELS`, plus an `index.json` naming them (default output
// dir: `public/locales`).
//
// Invoked in two places, following `build-icons.mjs`:
//   - the `dev` npm script, before the rsbuild dev server starts, and
//   - the `Build locale assets` CI step, after `nix build .#frontend`, writing
//     into `./dist/locales` before the Netlify deploy.
//
// The Nix build itself does not run this (the sandbox has no network); the CI
// step does. A locale a deploy did not write is one the dropdown does not offer,
// so neither the dev server nor the deploy blocks on a transient error.
//
// A search response is a POST and is therefore never cached, which is why the
// translations do not travel inside one: all 146 locales in every response would
// cost more than the icons did before they became files. A locale file is a GET
// named after a language, so a visitor pays for the one they read, once.

import { writeFileSync, mkdirSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUT_DIR = process.env.LOCALES_OUT_DIR || join(__dirname, "../public/locales");

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

// One document per locale, so a page covers every language a channel has.
const PAGE_SIZE = 500;

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

// Desktop files name a locale the POSIX way, as
// `language_COUNTRY.ENCODING@MODIFIER`; a browser names one the BCP 47 way, as
// `language-COUNTRY`. The two are reconciled here rather than in the frontend,
// so that what the dropdown offers is directly comparable to
// `navigator.languages` and is also a name that needs no escaping as a path.
const POSIX_LOCALE = /^([A-Za-z]{2,3})(?:_([A-Za-z]{2,3}))?(?:\.[A-Za-z0-9-]+)?(?:@([A-Za-z0-9]+))?$/;

// Modifiers that name a script. Anything else stays as a private-use subtag
// rather than being dropped: two scripts of one language translate the same
// string differently, and merging them would pick one at random.
const SCRIPT_MODIFIERS = { latin: "Latn", cyrillic: "Cyrl" };

function toBcp47(locale) {
    const match = POSIX_LOCALE.exec(locale);
    if (!match) return null;
    const [, language, region, modifier] = match;
    return [
        language.toLowerCase(),
        modifier
            ? SCRIPT_MODIFIERS[modifier.toLowerCase()] ||
              `x-${modifier.toLowerCase()}`
            : null,
        region ? region.toUpperCase() : null,
    ]
        .filter(Boolean)
        .join("-");
}

/** What speakers of a language call it, for the dropdown. */
function displayName(tag) {
    try {
        return new Intl.DisplayNames([tag], { type: "language" }).of(tag) || tag;
    } catch (_) {
        return tag;
    }
}

async function fetchPage(branch, searchAfter) {
    const index = `latest-${ELASTICSEARCH_MAPPING_SCHEMA_VERSION}-${branch}`;
    const url = `${ELASTICSEARCH_URL}/${index}/_search`;
    const body = JSON.stringify({
        size: PAGE_SIZE,
        _source: ["localization_locale", "localization_strings"],
        // An index written before this schema knew about localization has no
        // mapping for the sort field, which is an error rather than an empty
        // result unless `unmapped_type` says what to assume. That index is the
        // normal state while `import` runs ahead of `frontend`, so it has to
        // read as "no translations yet" and leave a real outage to stand out.
        sort: [
            { localization_locale: { order: "asc", unmapped_type: "keyword" } },
        ],
        query: { bool: { filter: [{ term: { type: "localization" } }] } },
        ...(searchAfter ? { search_after: searchAfter } : {}),
    });

    const headers = { "Content-Type": "application/json" };
    if (authHeader) headers["Authorization"] = authHeader;
    const res = await fetch(url, { method: "POST", headers, body });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return (await res.json())?.hits?.hits ?? [];
}

// Pooled across channels: a translation is a property of the string, not of the
// channel it was found in, so a stable channel and an unstable one contribute to
// one file and the newer wins where they disagree.
const locales = new Map();

for (const channel of channels) {
    const { id, branch } = channel;
    let searchAfter = null;
    let count = 0;

    try {
        for (;;) {
            const hits = await fetchPage(branch, searchAfter);
            if (hits.length === 0) break;
            for (const hit of hits) {
                const { localization_locale, localization_strings } =
                    hit._source;
                const tag = toBcp47(localization_locale);
                if (!tag) {
                    throw new Error(
                        `unexpected locale ${localization_locale}`,
                    );
                }
                count += 1;
                if (!locales.has(tag)) locales.set(tag, {});
                Object.assign(locales.get(tag), localization_strings);
            }
            if (hits.length < PAGE_SIZE) break;
            searchAfter = hits[hits.length - 1].sort;
        }
    } catch (err) {
        hadFailure = true;
        console.warn(`[locales] ${id}: ${err.message} — skipping the rest`);
    }

    console.log(`[locales] ${id}: ${count} locales`);
}

// Sorted, so that an import that changed nothing writes the same bytes and the
// file stays cached.
const manifest = [...locales.keys()].sort().map((tag) => {
    const strings = locales.get(tag);
    const sorted = Object.fromEntries(
        Object.keys(strings)
            .sort()
            .map((key) => [key, strings[key]]),
    );
    writeFileSync(join(OUT_DIR, `${tag}.json`), JSON.stringify(sorted));
    return { locale: tag, name: displayName(tag), strings: Object.keys(sorted).length };
});

// What the dropdown offers. Ordered by how much of the corpus each language
// covers, so the ones worth picking come first.
manifest.sort((a, b) => b.strings - a.strings || a.locale.localeCompare(b.locale));
writeFileSync(join(OUT_DIR, "index.json"), JSON.stringify(manifest));

console.log(`[locales] ${manifest.length} locales written to ${OUT_DIR}`);

if (hadFailure) {
    console.error(
        "[locales] one or more fetches failed — languages may be missing",
    );
    if (process.env.CI) {
        process.exit(1);
    }
}
