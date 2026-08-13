#!/usr/bin/env node
/**
 * Relevance benchmark test driver
 *
 * scores curated queries against our live ES instance.
 *
 * Usage:
 *   node benchmark/run.mjs [--packages <path>] [--options <path>] [--channel <branch>] [--schema <n>] [--k <n>] [--persistence <f>]
 *
 * Each curated query is an object:
 *
 *   id          stable handle, also the sort key of the per-query table
 *   q           the search term, as a user would type it
 *   category    grouping for the by-category table, e.g. `typo` or `intent`
 *   relevant    ids we accept as answers, `pkg:`/`opt:` prefixed
 *   exhaustive  optional; `relevant` enumerates *every* acceptable answer, so
 *               anything else on the page counts as noise. Required for RBP.
 *   best        optional; the single answer a user typing `q` is most likely
 *               after, which must be one of `relevant`. Required for BestRR
 *               unless `relevant` holds exactly one id. Leave it off where the
 *               gold set has no obvious winner - `text editor` has no business
 *               claiming `emacs` beats `vim`.
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
        persistence: { type: "string", default: "0.8" },
    },
    strict: false,
});

// Settings
const K = parseInt(args.k, 10);
const P = parseFloat(args.persistence);
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

// The one answer a user typing this query is most likely after, or `null` where
// we decline to rank the gold set. A single-entry `relevant` needs no
// annotation: with nothing to compare against, it is the best answer by
// definition. Beyond that it takes an explicit `"best"`, so ordering claims are
// only ever made where a curator wrote one down.
function bestAnswer(q) {
    if (q.best !== undefined) {
        if (!q.relevant.includes(q.best)) {
            throw new Error(`${q.id}: "best" ${q.best} is not in "relevant"`);
        }
        return q.best;
    }
    return q.relevant.length === 1 ? q.relevant[0] : null;
}

// Reciprocal rank of the best answer, rather than of the first relevant hit.
//
// MRR asks "did we surface something usable", which a cluster gold set answers
// trivially: on `node`, every `nodejs*` variant is relevant, so MRR reads 1.000
// whether `nodejs` or `nodejs-slim_26` came first. BestRR asks the ordinal
// question instead - "did the answer they wanted come first" - and separates
// those two pages 1.000 to 0.167.
//
// It collapses to MRR on a single-answer query, so it only speaks up on the
// cluster queries it was added for. Returns `null` when the query makes no
// ordinal claim, which drops it from the mean.
function bestReciprocalRank(ranked, best) {
    if (best === null) return null;
    const i = ranked.indexOf(best);
    return i === -1 ? 0 : 1 / (i + 1);
}

// Graded nDCG (Jarvelin & Kekalainen 2002) over two grades: the best answer
// scores 2, any other relevant hit 1.
//
// Where BestRR prices one position, this prices the whole page against its ideal
// ordering, so demoting a variant below the canonical package pays off even when
// the canonical package was already first. A query with no best answer keeps a
// flat grade of 1 across its gold set, which is ordinary binary nDCG - it still
// scores, it just states no preference within the set.
function ndcgAtK(ranked, q, k) {
    const best = bestAnswer(q);
    const grade = (id) => (id === best ? 2 : q.relevant.includes(id) ? 1 : 0);
    const gain = (g, i) => g / Math.log2(i + 2);

    const dcg = ranked
        .slice(0, k)
        .reduce((a, id, i) => a + gain(grade(id), i), 0);
    const ideal = q.relevant
        .map(grade)
        .sort((a, b) => b - a)
        .slice(0, k);
    const idcg = ideal.reduce((a, g, i) => a + gain(g, i), 0);
    return idcg > 0 ? dcg / idcg : 0;
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

// Rank-biased precision (Moffat & Zobel 2008), conditioned on the user stopping
// inside the page we returned.
//
// The user model: a user reads rank 1, then moves on to the next rank with
// probability `p`. So rank `i` is examined with weight `p^(i-1)`.
//
//   RBP = sum(p^(i-1) over relevant hits) / sum(p^(i-1) over returned hits)
//
// Textbook RBP divides by `1 / (1 - p)`, the weight of an unbounded result list.
// Dividing by the weight of the hits actually returned conditions the same model
// on the user stopping inside the page, since
// `sum(p^(i-1), i=1..n) = (1 - p^n) / (1 - p)`.
//
// Properties:
// - Junk anywhere on the page costs something, discounted by rank.
// - A page holding fewer than `k` hits is scored on what it returned, so a short
//   clean page reaches 1.000.
// - `p` sets how far down the user reads: expected examination depth is
//   `1 / (1 - p)` results.
//
// Requires `"exhaustive": true`, meaning `relevant` enumerates every acceptable
// answer; otherwise a good-but-unlisted hit scores as noise. Returns `null` when
// there are no hits, which drops the query from the mean.
function conditionalRBP(ranked, relevant, p) {
    if (ranked.length === 0) return null;
    const rel = new Set(relevant);
    let num = 0,
        denom = 0;
    for (let i = 0; i < ranked.length; i++) {
        const weight = p ** i;
        denom += weight;
        if (rel.has(ranked[i])) num += weight;
    }
    return num / denom;
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
            matched: data.hits.total.value,
            matchedExact: data.hits.total.relation === "eq",
            mrr: reciprocalRank(ranked, q.relevant),
            success: successAtK(ranked, q.relevant, K),
            recall: recallAtK(ranked, q.relevant, K),
            rbp: q.exhaustive ? conditionalRBP(ranked, q.relevant, P) : null,
            bestrr: bestReciprocalRank(ranked, bestAnswer(q)),
            ndcg: ndcgAtK(ranked, q, K),
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
    // RBP only covers the closed-set queries that returned something, BestRR
    // only the ones that name a best answer.
    const closed = results.filter((r) => r.rbp !== null);
    const ordinal = results.filter((r) => r.bestrr !== null);
    const overall = {
        success: mean(results.map((r) => r.success)),
        mrr: mean(results.map((r) => r.mrr)),
        recall: mean(results.map((r) => r.recall)),
        rbp: closed.length ? mean(closed.map((r) => r.rbp)) : null,
        bestrr: ordinal.length ? mean(ordinal.map((r) => r.bestrr)) : null,
        ndcg: mean(results.map((r) => r.ndcg)),
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
            ["metric", "value", "n"],
            [
                ["Success@" + K, overall.success.toFixed(3), results.length],
                ["MRR", overall.mrr.toFixed(3), results.length],
                ["Recall@" + K, overall.recall.toFixed(3), results.length],
                [
                    `RBP (p=${P})`,
                    overall.rbp === null ? "-" : overall.rbp.toFixed(3),
                    closed.length,
                ],
                [
                    "BestRR",
                    overall.bestrr === null ? "-" : overall.bestrr.toFixed(3),
                    ordinal.length,
                ],
                ["nDCG@" + K, overall.ndcg.toFixed(3), results.length],
            ],
        ),
        "",
        "### By category",
        "",
        table(
            [
                "category",
                "n",
                "Success@" + K,
                "MRR",
                "Recall@" + K,
                `RBP (p=${P})`,
                "BestRR",
                "nDCG@" + K,
            ],
            Object.entries(byCategory)
                .sort(([a], [b]) => a.localeCompare(b))
                .map(([cat, rs]) => {
                    // Cluster gold sets move Recall, RBP and BestRR, not
                    // Success/MRR, so a category is unreadable without them all.
                    const rbps = rs.filter((r) => r.rbp !== null);
                    const ords = rs.filter((r) => r.bestrr !== null);
                    return [
                        cat,
                        String(rs.length),
                        mean(rs.map((r) => r.success)).toFixed(3),
                        mean(rs.map((r) => r.mrr)).toFixed(3),
                        mean(rs.map((r) => r.recall)).toFixed(3),
                        rbps.length
                            ? `${mean(rbps.map((r) => r.rbp)).toFixed(3)} (n=${rbps.length})`
                            : "-",
                        ords.length
                            ? `${mean(ords.map((r) => r.bestrr)).toFixed(3)} (n=${ords.length})`
                            : "-",
                        mean(rs.map((r) => r.ndcg)).toFixed(3),
                    ];
                }),
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
    `> Index: \`${INDEX}\`. metrics: (Success@${K}, MRR, Recall@${K}, RBP(p=${P}), BestRR, nDCG@${K}).`,
    "",
    `> \`RBP\` is rank-biased precision. It prices rank \`i\` at \`p^(i-1)\`. Junk near the`,
    `> top therefore costs more than junk near the bottom. The denominator is the page`,
    `> we returned, so a short page scores only on the hits it has. Pass`,
    `> \`--persistence\` to change \`p\`. Only a query with \`"exhaustive": true\` gets a`,
    "> score. A query with no hits drops out of the mean.",
    "",
    "> `BestRR` and `nDCG` grade the gold set instead of treating it as a flat",
    "> set: the best answer counts double. `BestRR` is the reciprocal rank of that",
    "> one answer, so it reads how well we order results a user considers",
    "> comparably relevant, which `MRR` cannot see. It scores a query whose",
    '> `relevant` holds one entry or which names a `"best"`, and drops the rest',
    "> from the mean.",
    "",
    ...section("Packages", pkgResults),
    ...section("Options", optResults),
    "<details>",
    "<summary>Per-query results</summary>",
    "",
    "> `matched` is the size of the match set, and a `+` means ES stopped counting.",
    "",
    table(
        [
            "id",
            "track",
            "q",
            "category",
            "success",
            "mrr",
            "RBP",
            "BestRR",
            "nDCG",
            "matched",
            "top-3 ranked",
        ],
        perQuery.map((r) => [
            r.id,
            r.track,
            r.q,
            r.category,
            r.success.toFixed(0),
            r.mrr.toFixed(3),
            r.rbp === null ? "-" : r.rbp.toFixed(3),
            r.bestrr === null ? "-" : r.bestrr.toFixed(3),
            r.ndcg.toFixed(3),
            r.matched + (r.matchedExact ? "" : "+"),
            r.ranked.slice(0, 3).join(", "),
        ]),
    ),
    "",
    "</details>",
];

console.log(lines.join("\n"));
