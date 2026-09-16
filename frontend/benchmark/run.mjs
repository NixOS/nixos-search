#!/usr/bin/env node
/**
 * Relevance benchmark test driver
 *
 * scores curated queries against our live ES instance.
 *
 * Usage:
 *   node benchmark/run.mjs [--packages <path>] [--options <path>] [--channel <branch>] [--schema <n>] [--index <name>] [--k <n>] [--persistence <f>]
 *
 * `--index` names a concrete index instead of the `latest-<schema>-<channel>`
 * alias, which pins an A/B to one nixpkgs evaluation once the alias has moved
 * on to a newer one.
 *
 * Each curated query is an object:
 *
 *   id          stable handle, also the sort key of the per-query table
 *   q           the search term, as a user would type it
 *   category    the one axis this query is here to exercise, e.g. `typo` or
 *               `attrpath`. Also the unit the aggregate is weighted in, so
 *               every category needs an entry in `WEIGHTS` and vice versa.
 *               Where a query fits more than one, the rarer axis wins: an
 *               uppercase name is `cased` before it is `exact`, and a bare last
 *               segment is `leaf` before it is `cased`.
 *   relevant    tiers of ids we accept as answers, `pkg:`/`opt:` prefixed. Each
 *               tier is a list of ids tied at that rank: order *between* tiers
 *               is a claim, order *within* one is not. `[[a, b, c]]` states no
 *               preference, `[[a], [b], [c]]` is a strict order, and
 *               `[[a], [b, c]]` is a best answer followed by a tie. Only tier a
 *               gold set where the ordering is real - `text editor` has no
 *               business claiming `emacs` beats `vim`.
 *   exhaustive  optional; `relevant` enumerates *every* acceptable answer, so
 *               anything else on the page counts as noise. Required for RBP.
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
        index: { type: "string" },
        k: { type: "string", default: "10" },
        persistence: { type: "string", default: "0.8" },
    },
    strict: false,
});

// Settings
const K = parseInt(args.k, 10);
const P = parseFloat(args.persistence);
const SCHEMA = args.schema ?? frontendSchema();
const INDEX = args.index ?? `latest-${SCHEMA}-${args.channel}`;
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

// The gold set as ranked tiers, validated. A tier is a non-empty list of ids
// tied at that rank, and an id belongs to exactly one of them.
function tiers(q) {
    if (!Array.isArray(q.relevant) || q.relevant.length === 0) {
        throw new Error(`${q.id}: "relevant" must be a non-empty list of tiers`);
    }
    const seen = new Set();
    for (const tier of q.relevant) {
        if (!Array.isArray(tier) || tier.length === 0) {
            throw new Error(
                `${q.id}: every tier of "relevant" must be a non-empty list of ids, got ${JSON.stringify(tier)}`,
            );
        }
        for (const id of tier) {
            if (typeof id !== "string") {
                throw new Error(
                    `${q.id}: tier entry ${JSON.stringify(id)} is not a string`,
                );
            }
            if (seen.has(id)) {
                throw new Error(`${q.id}: ${id} appears in more than one tier`);
            }
            seen.add(id);
        }
    }
    return q.relevant;
}

// The gold set flattened back to a plain set of acceptable answers, which is
// what the membership metrics ask for.
function flatRelevant(q) {
    return tiers(q).flat();
}

function reciprocalRank(ranked, relevant) {
    const rel = new Set(relevant);
    for (let i = 0; i < ranked.length; i++) {
        if (rel.has(ranked[i])) return 1 / (i + 1);
    }
    return 0;
}

// The one answer a user typing this query is most likely after, or `null` where
// the gold set declines to name one. The top tier holds it whenever that tier
// holds a single id - including the single-answer case, where with nothing to
// compare against it is the best answer by definition. A tie at the top states
// no preference, so there is no ordinal claim to score.
function bestAnswer(q) {
    const top = tiers(q)[0];
    return top.length === 1 ? top[0] : null;
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

// Graded nDCG (Jarvelin & Kekalainen 2002) over the gold set's tiers: a hit in
// tier `i` of `T` grades `T - i`, and anything off the gold set grades 0.
//
// Where BestRR prices one position, this prices the whole page against its ideal
// ordering, so demoting a variant below the canonical package pays off even when
// the canonical package was already first. A single-tier query keeps a flat
// grade of 1 across its gold set, which is ordinary binary nDCG - it still
// scores, it just states no preference within the set.
function ndcgAtK(ranked, q, k) {
    const gold = tiers(q);
    const grades = new Map(
        gold.flatMap((tier, i) => tier.map((id) => [id, gold.length - i])),
    );
    const gain = (g, i) => g / Math.log2(i + 2);

    const dcg = ranked
        .slice(0, k)
        .reduce((a, id, i) => a + gain(grades.get(id) ?? 0, i), 0);
    // Tiers are already in descending grade order, so this is the ideal page.
    const idcg = gold
        .flatMap((tier, i) => tier.map(() => gold.length - i))
        .slice(0, k)
        .reduce((a, g, i) => a + gain(g, i), 0);
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
        const relevant = flatRelevant(q);
        results.push({
            id: q.id,
            q: q.q,
            category: q.category,
            relevant: q.relevant,
            ranked,
            matched: data.hits.total.value,
            matchedExact: data.hits.total.relation === "eq",
            mrr: reciprocalRank(ranked, relevant),
            success: successAtK(ranked, relevant, K),
            recall: recallAtK(ranked, relevant, K),
            rbp: q.exhaustive ? conditionalRBP(ranked, relevant, P) : null,
            bestrr: bestReciprocalRank(ranked, bestAnswer(q)),
            ndcg: ndcgAtK(ranked, q, K),
        });
    }
    return results;
}

const pkgQueries = JSON.parse(readFileSync(args.packages, "utf8"));
const optQueries = JSON.parse(readFileSync(args.options, "utf8"));

// What share of the aggregate each category is worth.
//
// Curated queries are not a sample of anything - they were written down, not
// observed - so an unweighted mean reports how we do on the mix we happened to
// invent. `corpus/observed-queries.json` holds real queries mined from shared
// `search.nixos.org/...?query=` links, and `corpus/mine.mjs` prints the shape
// distribution the numbers below cite. Re-run it when these are up for review.
//
// The corpus has a bias the weights have to respect: a shared link is a link
// that *worked*, so it can price the plain/dotted/cased/versioned mix but is
// blind to typos and to failed natural-language queries. Where it can see, the
// weight follows the observation; where it cannot, the weight is judgement and
// says so.
//
// Weighting at the category level rather than per query is what lets the query
// sets grow: adding a query sharpens its category's estimate without shifting
// the mix. Each table sums to 1.
const WEIGHTS = {
    // Observed (n=808): plain 84.5%, dotted 6.2%, cased 4.8%, multiterm 2.4%,
    // versioned 2.1%.
    packages: {
        exact: 0.4, // share of the plain block
        prefix: 0.22, // judgement: every typed search passes through prefix
        // states and the typeahead queries them, but the corpus only ever sees
        // the query that got shared
        typo: 0.1, // judgement: the corpus cannot see these at all
        intent: 0.08, // judgement: a natural-language query that failed is the
        // least likely to be shared and the one we most want to fix
        attrpath: 0.06, // observed 6.2%
        cased: 0.05, // observed 4.8%
        multiterm: 0.05, // observed 2.4%, upweighted alongside `intent`
        versioned: 0.04, // observed 2.1%
    },
    // Observed (n=436): plain 45.4%, dotted 41.1% (depth 1: 109, depth 2: 58,
    // depth 3+: 18), cased 8.0%, multiterm 5.5%. 20.6% carry an uppercase
    // letter somewhere, most of them inside a path.
    options: {
        exact: 0.24, // share of the plain block
        scoped: 0.22, // a module plus the setting inside it - the same shape as
        // the depth-1 end of the dotted block, which is most of it
        dotted: 0.16, // literal paths, the depth-2+ end of that block
        prefix: 0.1, // judgement, as above
        leaf: 0.06, // observed: bare leaf names, e.g. `systemPackages`
        cased: 0.06, // observed: uppercase inside a path
        typo: 0.06, // judgement
        multiterm: 0.05, // observed 5.5%
        intent: 0.05, // judgement
    },
};

// A category with no weight would silently drop out of the aggregate and a
// weight with no category would silently renormalize the rest, so both are
// errors, and both are worth hearing about before a scoring run rather than
// after it.
function checkWeights(track, queries, weights) {
    const present = new Set(queries.map((q) => q.category));
    for (const category of [...present].sort()) {
        if (!(category in weights)) {
            throw new Error(
                `${track}: category "${category}" has no weight in WEIGHTS.${track}`,
            );
        }
    }
    for (const category of Object.keys(weights)) {
        if (!present.has(category)) {
            throw new Error(
                `${track}: WEIGHTS.${track}.${category} has no queries`,
            );
        }
    }
    const total = Object.values(weights).reduce((a, b) => a + b, 0);
    if (Math.abs(total - 1) > 1e-6) {
        throw new Error(
            `${track}: WEIGHTS.${track} sums to ${total.toFixed(4)}, not 1`,
        );
    }
}

checkWeights("packages", pkgQueries, WEIGHTS.packages);
checkWeights("options", optQueries, WEIGHTS.options);

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

// Each category contributes `WEIGHTS[track][category]` to the aggregate, split
// evenly across its members. Renormalizing by the weight actually present lets
// the metrics that drop queries (RBP, BestRR) reuse this unchanged: a category
// that contributes nothing to a metric simply leaves its weight out.
function weightedMean(rows, weights, pick) {
    const byCategory = {};
    for (const r of rows) {
        (byCategory[r.category] ??= []).push(pick(r));
    }
    let weighted = 0,
        present = 0;
    for (const [category, values] of Object.entries(byCategory)) {
        weighted += weights[category] * mean(values);
        present += weights[category];
    }
    return present > 0 ? weighted / present : null;
}

const table = (header, rows) =>
    [
        `| ${header.join(" | ")} |`,
        `| ${header.map(() => "---").join(" | ")} |`,
        ...rows.map((r) => `| ${r.join(" | ")} |`),
    ].join("\n");

// Metric labels paired with the footnote GitHub renders at the bottom of the
// report. Every table names a metric through `metric()`, so each definition is
// written once and the term links there where the report first uses it.
const METRICS = {
    success: {
        label: `Success@${K}`,
        note: `Did the page hold an acceptable answer at all - 1 or 0 per
            query.`,
    },
    mrr: {
        label: "MRR",
        note: `Mean reciprocal rank of the first acceptable answer: 1.000 if it
            led, 0.500 second, 0.333 third, 0 if none made the page.`,
    },
    recall: {
        label: `Recall@${K}`,
        note: `What share of the acceptable answers the page held, over the most
            it could have held at k.`,
    },
    rbp: {
        label: `RBP (p=${P})`,
        note: `Rank-biased precision (Moffat & Zobel 2008): how much of the page
            a user is expected to find useful, pricing rank \`i\` at \`p^(i-1)\`
            so junk near the top costs more than junk near the bottom. \`p\` is
            the chance they read one more result; the denominator is the page we
            returned, so a short clean page still reaches 1.000.`,
    },
    bestrr: {
        label: "BestRR",
        note: `Reciprocal rank of the one answer the query most wants: 1.000 if
            it led, 0.500 second, 0 if it never appeared. Where MRR is satisfied
            by any acceptable answer, this reads the ordering within that set -
            on \`node\` MRR is 1.000 whether \`nodejs\` or \`nodejs-slim_26\`
            led, and BestRR separates those pages 1.000 to 0.167. The gold set
            is a list of tiers of ids tied at a rank; the best answer is a top
            tier holding one id.`,
    },
    ndcg: {
        label: `nDCG@${K}`,
        note: `Normalized discounted cumulative gain (Jarvelin & Kekalainen
            2002): the whole page priced against its ideal ordering, 1.000 when
            nothing could have been ranked better. A hit in tier \`i\` of \`T\`
            grades \`T - i\`, so a one-tier gold set is ordinary binary nDCG.`,
    },
    weight: {
        label: "weight",
        note: `What share of the \`Overall\` figures the category is worth,
            split evenly across its queries. Set from the shape of the real
            queries in \`corpus/observed-queries.json\` where that corpus can
            see them, and by stated judgement where it cannot - it is mined from
            shared links, so it is blind to the searches that failed. Weighting
            per category rather than per query means adding a query sharpens its
            category without moving the mix.`,
    },
    n: {
        label: "n",
        note: `How many queries the figure covers; the rest make no claim the
            metric can read and drop out of its mean. RBP covers queries marked
            \`"exhaustive": true\`, meaning the gold set lists every acceptable
            answer so anything else is noise, that returned at least one hit.
            BestRR covers queries whose gold set names a single best answer.`,
    },
};

// A footnote definition has to be one line; wrap the source, not the output.
const oneLine = (s) => s.trim().replace(/\s+/g, " ");

// A metric named in a table. Only the first mention carries the footnote
// marker - the seven metrics land in the first `Overall` table and `weight` in
// the first `By category` one - because the reference is there to introduce the
// term, and repeating it on every table leaves the reader looking past markers
// to reach the numbers.
const cited = new Set();
const metric = (key) => {
    const first = !cited.has(key);
    cited.add(key);
    return METRICS[key].label + (first ? `[^${key}]` : "");
};

const FOOTNOTES = Object.entries(METRICS).map(
    ([key, { note }]) => `[^${key}]: ${oneLine(note)}`,
);

// One `## <label>` section: Overall + By-category tables for a single track.
function section(label, results, weights) {
    // RBP only covers the closed-set queries that returned something, BestRR
    // only the ones that name a best answer.
    const closed = results.filter((r) => r.rbp !== null);
    const ordinal = results.filter((r) => r.bestrr !== null);
    const agg = (rows, pick) => weightedMean(rows, weights, pick);
    const overall = {
        success: agg(results, (r) => r.success),
        mrr: agg(results, (r) => r.mrr),
        recall: agg(results, (r) => r.recall),
        rbp: agg(closed, (r) => r.rbp),
        bestrr: agg(ordinal, (r) => r.bestrr),
        ndcg: agg(results, (r) => r.ndcg),
    };
    const byCategory = {};
    for (const r of results) {
        (byCategory[r.category] ??= []).push(r);
    }
    return [
        `## ${label}`,
        "",
        `> ${results.length} queries in ${Object.keys(byCategory).length} categories.`,
        "",
        "### Overall",
        "",
        `> Weighted by category, so the figures track the query mix real users
         type rather than the mix we happened to curate. The weights and where
         they come from are in \`WEIGHTS\` in \`run.mjs\`.`.replace(/\s+/g, " "),
        "",
        table(
            ["metric", "value", metric("n")],
            [
                [metric("success"), overall.success.toFixed(3), results.length],
                [metric("mrr"), overall.mrr.toFixed(3), results.length],
                [metric("recall"), overall.recall.toFixed(3), results.length],
                [
                    metric("rbp"),
                    overall.rbp === null ? "-" : overall.rbp.toFixed(3),
                    closed.length,
                ],
                [
                    metric("bestrr"),
                    overall.bestrr === null ? "-" : overall.bestrr.toFixed(3),
                    ordinal.length,
                ],
                [metric("ndcg"), overall.ndcg.toFixed(3), results.length],
            ],
        ),
        "",
        "### By category",
        "",
        `> Unweighted - a category's mean is what it is. The \`weight\` column is
         the share it contributed to \`Overall\` above.`.replace(/\s+/g, " "),
        "",
        table(
            [
                "category",
                metric("weight"),
                metric("n"),
                metric("success"),
                metric("mrr"),
                metric("recall"),
                metric("rbp"),
                metric("bestrr"),
                metric("ndcg"),
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
                        weights[cat].toFixed(2),
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
    `> Index: \`${INDEX}\`, k=${K}. Metric definitions are in the footnotes.`,
    "",
    ...section("Packages", pkgResults, WEIGHTS.packages),
    ...section("Options", optResults, WEIGHTS.options),
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
    "",
    ...FOOTNOTES,
];

console.log(lines.join("\n"));
