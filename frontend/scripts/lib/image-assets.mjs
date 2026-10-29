// Writes the images an Elasticsearch index holds as static files, one per
// document, named after the image so that `<img src>` in a result card has
// something to point at. `build-icons.mjs` and `build-screenshots.mjs` are the
// two callers: an icon and a screenshot differ only in the document type, the
// fields that carry them and the directory they are written to.
//
// Each caller is invoked in two places, following
// `build-autocomplete-corpus.mjs`:
//   - the `dev` npm script, before the rsbuild dev server starts, and
//   - a `Build ... assets` CI step, after `nix build .#frontend`, writing into
//     `./dist` before the Netlify deploy.
//
// The Nix build itself does not run these (the sandbox has no network); the CI
// steps do. An image a deploy did not write renders as nothing rather than as a
// broken image, so neither the dev server nor the deploy blocks on a transient
// error.
//
// An image's name is derived from its contents, so it is the same file across
// channels and across imports. That makes each file safe to cache indefinitely.
//
// The images are not in the channel indices. `flake-info` puts them into one
// index for each schema version, which all channels and imports share, with the
// alias `latest-<version>-images`. Each image is in that index one time.

import { writeFileSync, mkdirSync } from "fs";
import { join } from "path";

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

// The images of all channels are more than the 10000 `from + size` limit, thus
// the pages are read with `search_after` over the name field and not by offset.
const PAGE_SIZE = 1000;

// A page usually arrives in about one second. Sometimes the cluster stalls on
// one, and the proxy in front of it then closes the connection after 60 seconds.
// A page that takes longer than the timeout is thus requested again, and the
// script fails only after all attempts fail.
const FETCH_TIMEOUT_MS = 20_000;
const FETCH_ATTEMPTS = 3;
const RETRY_DELAY_MS = 2_000;

// A name reaches this script over the network and is then used as a path, so it
// is checked against the shape `flake-info` gives it rather than trusted to
// stay inside the output directory.
const IMAGE_FILE = /^[0-9a-f]{32}\.[a-z]+$/;

const authHeader =
    ELASTICSEARCH_USERNAME || ELASTICSEARCH_PASSWORD
        ? "Basic " +
          Buffer.from(
              `${ELASTICSEARCH_USERNAME}:${ELASTICSEARCH_PASSWORD}`,
          ).toString("base64")
        : null;

async function fetchPage(label, type, fileField, dataField, searchAfter) {
    const index = `latest-${ELASTICSEARCH_MAPPING_SCHEMA_VERSION}-images`;
    // Before the first import of a schema version, its image index does not
    // exist. `ignore_unavailable` makes that an empty result and not an error,
    // as `unmapped_type` does below for a missing field.
    const url = `${ELASTICSEARCH_URL}/${index}/_search?ignore_unavailable=true`;
    const body = JSON.stringify({
        size: PAGE_SIZE,
        _source: [fileField, dataField],
        // An index written before this schema knew about the image has no
        // mapping for the sort field, which is an error rather than an empty
        // result unless `unmapped_type` says what to assume. That index is the
        // normal state while `import` runs ahead of `frontend`, so it has to
        // read as "no images yet" and leave a real outage to stand out.
        sort: [{ [fileField]: { order: "asc", unmapped_type: "keyword" } }],
        query: { bool: { filter: [{ term: { type } }] } },
        ...(searchAfter ? { search_after: searchAfter } : {}),
    });

    const headers = { "Content-Type": "application/json" };
    if (authHeader) headers["Authorization"] = authHeader;

    for (let attempt = 1; ; attempt++) {
        try {
            // The signal also stops the body read, which is where a stalled
            // page waits.
            const res = await fetch(url, {
                method: "POST",
                headers,
                body,
                signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
            });
            if (!res.ok) {
                const err = new Error(`HTTP ${res.status}`);
                // A different request does not fix a 4xx status, other than
                // 429, so only a 429 or a 5xx status is retried.
                err.retry = res.status === 429 || res.status >= 500;
                throw err;
            }
            return (await res.json())?.hits?.hits ?? [];
        } catch (err) {
            if (err.retry === false || attempt === FETCH_ATTEMPTS) throw err;
            console.warn(
                `[${label}] ${err.message} -- attempt ${attempt} of ${FETCH_ATTEMPTS}, trying again`,
            );
            await new Promise((r) => setTimeout(r, RETRY_DELAY_MS * attempt));
        }
    }
}

/**
 * Writes one file per image document into `outDir`.
 *
 * @param {object} options
 * @param {string} options.label what the images are, for the log lines
 * @param {string} options.type the document type to read
 * @param {string} options.fileField the field holding the image's name
 * @param {string} options.dataField the field holding the image itself
 * @param {string} options.outDir the directory to write into
 */
export async function writeImages({
    label,
    type,
    fileField,
    dataField,
    outDir,
}) {
    mkdirSync(outDir, { recursive: true });

    let hadFailure = false;
    let searchAfter = null;
    let count = 0;

    try {
        for (;;) {
            const hits = await fetchPage(
                label,
                type,
                fileField,
                dataField,
                searchAfter,
            );
            if (hits.length === 0) break;
            for (const hit of hits) {
                const file = hit._source[fileField];
                if (!IMAGE_FILE.test(file)) {
                    throw new Error(`unexpected ${label} name ${file}`);
                }
                // The image is base64 only because the document holding it is
                // JSON; the name says what format the bytes are in.
                writeFileSync(
                    join(outDir, file),
                    Buffer.from(hit._source[dataField], "base64"),
                );
                count += 1;
            }
            if (hits.length < PAGE_SIZE) break;
            searchAfter = hits[hits.length - 1].sort;
        }
    } catch (err) {
        hadFailure = true;
        console.warn(`[${label}] ${err.message} -- skipping the rest`);
    }

    console.log(`[${label}] ${count} ${label} written to ${outDir}`);

    if (hadFailure) {
        console.error(
            `[${label}] one or more fetches failed -- ${label} may be missing`,
        );
        if (process.env.CI) {
            process.exit(1);
        }
    }
}
