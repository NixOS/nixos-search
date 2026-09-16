# Relevance benchmark

`run.mjs` scores the frontend's Elasticsearch query - the one `Search/Query.elm`
builds - against the deployed index, over two curated query files:

- `queries-packages.json`, scored against `package_attr_name`
- `queries-options.json`, scored against `option_name`

Run it with `npm --prefix frontend run benchmark`. It prints a markdown report;
the metric definitions are footnotes at the bottom of that report, and the query
file format is documented at the top of `run.mjs`.

## The aggregate is weighted by category

Curated queries are not a sample of anything. They were written down rather than
observed, so an unweighted mean answers "how do we do on the mix we happened to
invent", not "how do we do on the mix users actually type" - and those two mixes
are far apart. The curated files were 37:63 packages-to-options where real
traffic is 64:35, and had no attribute-path package queries at all against an
observed 6.2%.

So each `(track, category)` pair carries a weight in `WEIGHTS` in `run.mjs`, and
the six `Overall` figures are weighted means over the per-category means. The
`By category` table stays unweighted - a category's mean is what it is - and
carries a `weight` column showing how `Overall` was composed.

Weighting per category rather than per query is what keeps the query files
growable: a category contributes a fixed share split evenly across its members,
so adding a query sharpens that category's estimate without disturbing the mix.
Aim for at least a dozen queries in a category before trusting its row.

## Where the weights come from

`corpus/observed-queries.json` is a dated snapshot of real queries, mined from
shared `search.nixos.org/...?query=` links in public GitHub issues and pull
requests by `corpus/mine.mjs`. Nothing in our own stack records query text: the
cluster is Elasticsearch 7.10.2 OSS, so there is no behavioral-analytics
collection and no query-log index, and the frontend has no tracker. Shared links
are the only public place the text survives.

Re-run the miner when the weights are up for review:

```
GITHUB_TOKEN=$(gh auth token) node frontend/benchmark/corpus/mine.mjs
```

It rewrites the snapshot and prints the shape distribution the `WEIGHTS`
comments cite - a per-track split into `plain` / `dotted` / `cased` /
`versioned` / `multiterm`, plus token counts and a dotted-depth histogram. It is
deliberately not wired into CI: it needs a token, it hits the search rate limit,
and GitHub search is not deterministic. The committed snapshot is what CI-side
readers see.

**The corpus has a bias the weights have to respect.** A shared link is a link
that _worked_ - nobody pastes a search that found nothing. So the corpus can
price the shape mix of successful queries, and it is blind to typos,
misspellings and failed natural-language queries. It cannot be used to argue the
`typo` or `intent` weight down to its observed floor, and those two weights are
set by stated judgement instead. Every entry in `WEIGHTS` says which of the two
it is.

The last snapshot, mined 2026-08-19, holds 1255 queries: 64.4% packages, 34.7%
options, 0.9% flakes. Packages split plain 84.5%, dotted 6.2%, cased 4.8%,
multiterm 2.4%, versioned 2.1%. Options split plain 45.4%, dotted 41.1% (109 at
depth 1, 58 at depth 2, 18 deeper), cased 8.0%, multiterm 5.5%, and 20.6% carry
an uppercase letter somewhere.

The `flakes` track is not benchmarked. At 0.9% of observed queries it is not
worth a curated file yet.

## Categories

A query's `category` is the one axis it exists to exercise. Where a query fits
more than one, the rarer axis wins - an uppercase name is `cased` before it is
`exact`, and a bare last segment is `leaf` before it is `cased`.

Shared across both tracks:

| category    | what it tests                                                    |
| ----------- | ---------------------------------------------------------------- |
| `exact`     | the full name, spelled correctly                                 |
| `prefix`    | a name typed part-way, as the typeahead sees it                  |
| `typo`      | a name misspelled                                                |
| `multiterm` | two or more words                                                |
| `intent`    | a description of the thing rather than its name                  |
| `cased`     | mixed-case input: `MusicFree`, `services.postgresql.enableTCPIP` |

Packages only:

| category    | what it tests                                                      |
| ----------- | ------------------------------------------------------------------ |
| `attrpath`  | an attribute path into a package set: `vimPlugins.nvim-treesitter` |
| `versioned` | a version-suffixed attr name: `nodejs_24`, `lua5_3_compat`         |

Options only:

| category | what it tests                                              |
| -------- | ---------------------------------------------------------- |
| `dotted` | a literal attribute path: `services.paperless.domain`      |
| `scoped` | a module plus the setting inside it: `nginx virtual hosts` |
| `leaf`   | a bare last segment with no path: `systemPackages`         |

Ids are block-allocated per category, so a new category takes a fresh block and
adding a query never renumbers an existing one:

| block  | category    |
| ------ | ----------- |
| `g001` | `exact`     |
| `g100` | `prefix`    |
| `g150` | `typo`      |
| `g200` | `multiterm` |
| `g250` | `intent`    |
| `g300` | `cased`     |
| `g350` | `attrpath`  |
| `g400` | `versioned` |
| `g450` | `dotted`    |
| `g500` | `scoped`    |
| `g550` | `leaf`      |

A query that appears in both files carries the same id in both, which is what
pairs the `pkg` and `opt` rows for one query in the per-query table. Two
different queries must never share an id.

## Adding a category

1. Add the queries, taking their text from `corpus/observed-queries.json` where
   you can, so the category describes something users do rather than something
   we imagined. Give it a fresh id block.
2. Add its weight to that track's table in `WEIGHTS`, taking the weight back out
   of the categories it is carving from so the table still sums to 1. Say in the
   comment whether the number is observed or judgement.
3. Run the benchmark. `run.mjs` fails up front if a category has no weight, a
   weight has no queries, or a table does not sum to 1.
4. Check the new rows against the live index by hand before trusting them. A
   0.000 in a new category is more often a real ranking finding than a bad gold
   set - `python3Packages.absl-py` returns nothing because the index carries
   only the versioned package sets, and that is worth knowing.
