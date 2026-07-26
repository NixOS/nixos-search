#!/usr/bin/env node
/**
 * Relevance benchmark test driver
 *
 * scores curated queries against our live ES instance.
 *
 * Usage:
 *   node benchmark/run.mjs [--packages <path>] [--options <path>] [--channel <branch>] [--schema <n>] [--k <n>]
 *
 */

import { execSync } from "node:child_process";
import { createRequire } from "node:module";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, resolve } from "node:path";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FRONTEND_DIR = resolve(__dirname, "..");
const REPO_ROOT = resolve(FRONTEND_DIR, "..");

/// Grep the schema version
function frontendSchema() {
    const version_nix = readFileSync(join(REPO_ROOT, "version.nix"), "utf8");
    const match = version_nix.match(/frontend\s*=\s*"(\d+)"/);
    if (!match) {
        throw new Error("could not parse `frontend` schema from version.nix");
    }
    return match[1];
}

const { values: args } = parseArgs({
    args: process.argv.slice(2),
    options: {
        packages: {
            type: "string",
            default: join(__dirname, "queries-packages.json"),
        },
        options: {
            type: "string",
            default: join(__dirname, "queries-options.json"),
        },
        channel: { type: "string", default: "nixos-unstable" },
        schema: { type: "string" },
        k: { type: "string", default: "10" },
    },
    strict: false,
});

// Settings
const K = parseInt(args.k, 10);
const SCHEMA = args.schema ?? frontendSchema();
const INDEX = `latest-${SCHEMA}-${args.channel}`;
const ES_URL =
    process.env.ELASTICSEARCH_URL || "https://search.nixos.org/backend";
const ES_USER = process.env.ELASTICSEARCH_USERNAME || "aWVSALXpZv";
const ES_PASS =
    process.env.ELASTICSEARCH_PASSWORD || "X8gPHnzL52wFEekuxsfQ9cSh";
const AUTH = "Basic " + Buffer.from(`${ES_USER}:${ES_PASS}`).toString("base64");

// Compile elm
const tmpDir = mkdtempSync(join(tmpdir(), "nixos-search-benchmark-"));
const workerPath = join(tmpDir, "benchmark.js");
console.error(`[benchmark] compiling Benchmark.elm → ${workerPath}`);
execSync(
    `node_modules/.bin/elm make src/Benchmark.elm --optimize --output ${workerPath}`,
    { cwd: FRONTEND_DIR, stdio: ["ignore", "ignore", "inherit"] },
);

const require = createRequire(import.meta.url);
const { Elm } = require(workerPath);
const app = Elm.Benchmark.init({ flags: {} });

// Helpers
const RETRYABLE_STATUS = new Set([429, 502, 503, 504]);
const MAX_ATTEMPTS = 5;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function esSearch(bodyJson) {
    const url = `${ES_URL}/${INDEX}/_search`;
    let lastErr;
    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
        try {
            const resp = await fetch(url, {
                method: "POST",
                headers: {
                    "Content-Type": "application/json",
                    Authorization: AUTH,
                },
                body: bodyJson,
            });
            if (resp.ok) return resp.json();
            const text = await resp.text();
            // Non-retryable (e.g. auth/query errors): fail immediately.
            if (!RETRYABLE_STATUS.has(resp.status)) {
                throw new Error(`ES ${resp.status}: ${text}`);
            }
            lastErr = new Error(`ES ${resp.status}: ${text}`);
        } catch (err) {
            // fetch() rejects on network faults (ECONNRESET, DNS, TLS); retry those.
            if (err instanceof TypeError && err.cause) {
                lastErr = err;
            } else {
                throw err;
            }
        }
        if (attempt < MAX_ATTEMPTS) {
            // Exponential backoff with jitter: ~0.5s, 1s, 2s, 4s.
            const backoff = 500 * 2 ** (attempt - 1) + Math.random() * 250;
            console.error(
                `[benchmark] request failed (attempt ${attempt}/${MAX_ATTEMPTS}): ${lastErr.message}; retrying in ${Math.round(backoff)}ms`,
            );
            await sleep(backoff);
        }
    }
    throw lastErr;
}

// ES returns hits in score order per index, so no re-sort is needed;
// dedup is kept for parity with the previous merged ranker.
function rankHits(hits, field, prefix, k) {
    const out = [],
        seen = new Set();
    for (const h of hits) {
        const name = h._source?.[field];
        if (!name) continue;
        const id = prefix + name;
        if (seen.has(id)) continue;
        seen.add(id);
        out.push(id);
        if (out.length === k) break;
    }
    return out;
}

function reciprocalRank(ranked, relevant) {
    const rel = new Set(relevant);
    for (let i = 0; i < ranked.length; i++) {
        if (rel.has(ranked[i])) return 1 / (i + 1);
    }
    return 0;
}

function successAtK(ranked, relevant, k) {
    const rel = new Set(relevant);
    return ranked.slice(0, k).some((id) => rel.has(id)) ? 1 : 0;
}

function recallAtK(ranked, relevant, k) {
    const rel = new Set(relevant);
    const hits = ranked.slice(0, k).filter((id) => rel.has(id)).length;

    const denom = Math.min(k, rel.size);
    return denom > 0 ? hits / denom : 0;
}

function nextBody(query, k) {
    return new Promise((resolve) => {
        const sub = app.ports.gotBodies.subscribe(function handler(bodies) {
            app.ports.gotBodies.unsubscribe(handler);
            resolve(bodies);
        });
        app.ports.sendQuery.send({ query, k });
    });
}

// Score one curated file against a single index. `bodyKey` selects which of the
// two bodies the Elm worker emits; `field`/`prefix` build the ranked ids.
async function scoreTrack(queries, bodyKey, field, prefix) {
    const results = [];
    for (const q of queries) {
        const bodies = await nextBody(q.q, K);
        const data = await esSearch(bodies[bodyKey]);
        const ranked = rankHits(data.hits.hits, field, prefix, K);
        results.push({
            id: q.id,
            q: q.q,
            category: q.category,
            relevant: q.relevant,
            ranked,
            mrr: reciprocalRank(ranked, q.relevant),
            success: successAtK(ranked, q.relevant, K),
            recall: recallAtK(ranked, q.relevant, K),
        });
    }
    return results;
}

const pkgQueries = JSON.parse(readFileSync(args.packages, "utf8"));
const optQueries = JSON.parse(readFileSync(args.options, "utf8"));

console.error(
    `[benchmark] scoring ${pkgQueries.length} package queries against ${INDEX}`,
);
const pkgResults = await scoreTrack(
    pkgQueries,
    "packages",
    "package_attr_name",
    "pkg:",
);
console.error(
    `[benchmark] scoring ${optQueries.length} option queries against ${INDEX}`,
);
const optResults = await scoreTrack(
    optQueries,
    "options",
    "option_name",
    "opt:",
);

function mean(arr) {
    return arr.reduce((a, b) => a + b, 0) / arr.length;
}

const table = (header, rows) =>
    [
        `| ${header.join(" | ")} |`,
        `| ${header.map(() => "---").join(" | ")} |`,
        ...rows.map((r) => `| ${r.join(" | ")} |`),
    ].join("\n");

// One `## <label>` section: Overall + By-category tables for a single track.
function section(label, results) {
    const overall = {
        success: mean(results.map((r) => r.success)),
        mrr: mean(results.map((r) => r.mrr)),
        recall: mean(results.map((r) => r.recall)),
    };
    const byCategory = {};
    for (const r of results) {
        (byCategory[r.category] ??= []).push(r);
    }
    return [
        `## ${label}`,
        "",
        `> ${results.length} queries, k=${K}.`,
        "",
        "### Overall",
        "",
        table(
            ["metric", "value"],
            [
                ["Success@" + K, overall.success.toFixed(3)],
                ["MRR", overall.mrr.toFixed(3)],
                ["Recall@" + K, overall.recall.toFixed(3)],
            ],
        ),
        "",
        "### By category",
        "",
        table(
            ["category", "n", "Success@" + K, "MRR"],
            Object.entries(byCategory)
                .sort(([a], [b]) => a.localeCompare(b))
                .map(([cat, rs]) => [
                    cat,
                    String(rs.length),
                    mean(rs.map((r) => r.success)).toFixed(3),
                    mean(rs.map((r) => r.mrr)).toFixed(3),
                ]),
        ),
        "",
    ];
}

// Combined per-query table with a `track` column so a weak `pkg` row sits next
// to its `opt` sibling for the same query.
const perQuery = [
    ...pkgResults.map((r) => ({ track: "pkg", ...r })),
    ...optResults.map((r) => ({ track: "opt", ...r })),
].sort((a, b) => a.id.localeCompare(b.id) || a.track.localeCompare(b.track));

const lines = [
    "# Relevance benchmark: frontend query vs deployed ES",
    "",
    `> Index: \`${INDEX}\`. metrics: (Success@${K}, MRR, Recall@${K}).`,
    "",
    ...section("Packages", pkgResults),
    ...section("Options", optResults),
    "<details>",
    "<summary>Per-query results</summary>",
    "",
    table(
        ["id", "track", "q", "category", "success", "mrr", "top-3 ranked"],
        perQuery.map((r) => [
            r.id,
            r.track,
            r.q,
            r.category,
            r.success.toFixed(0),
            r.mrr.toFixed(3),
            r.ranked.slice(0, 3).join(", "),
        ]),
    ),
    "",
    "</details>",
];

console.log(lines.join("\n"));
