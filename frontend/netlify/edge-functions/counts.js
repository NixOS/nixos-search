// Count the documents of each `type` in each index that an `index` query
// parameter names, for example `/counts?index=latest-52-nixos-unstable`. The
// response has the form `{"<index>": {"<type>": <count>}}`.
//
// The counts change only when an import writes to an index. Thus the CDN and
// the browser keep the response for one day, and Elasticsearch gets few count
// queries.

const ELASTICSEARCH_URL =
    "https://nixos-search-7-1733963800.us-east-1.bonsaisearch.net";

// The same public read-only credentials that the frontend uses.
const ELASTICSEARCH_AUTHORIZATION =
    "Basic " + btoa("aWVSALXpZv:X8gPHnzL52wFEekuxsfQ9cSh");

const INDEX = /^latest-\d+-nixos-[a-z0-9._-]+$/;
const MAX_INDEXES = 10;
const ONE_DAY = 24 * 60 * 60;

// A `size: 0` search goes into the shard request cache of Elasticsearch.
const COUNT_QUERY = {
    size: 0,
    // More buckets than the number of document types, so each count is exact.
    aggs: { types: { terms: { field: "type", size: 100 } } },
};

export default async (request) => {
    const indexes = [
        ...new Set(new URL(request.url).searchParams.getAll("index")),
    ];
    if (
        indexes.length === 0 ||
        indexes.length > MAX_INDEXES ||
        !indexes.every((index) => INDEX.test(index))
    ) {
        return new Response(
            `Give 1 to ${MAX_INDEXES} \`index\` parameters of the form \`latest-<version>-nixos-<branch>\`.\n`,
            { status: 400, headers: { "Cache-Control": "no-store" } },
        );
    }

    // `_msearch` sends one search for each index in one request.
    const body = indexes
        .map(
            (index) =>
                `${JSON.stringify({ index })}\n${JSON.stringify(COUNT_QUERY)}\n`,
        )
        .join("");
    const response = await fetch(`${ELASTICSEARCH_URL}/_msearch`, {
        method: "POST",
        headers: {
            Authorization: ELASTICSEARCH_AUTHORIZATION,
            "Content-Type": "application/x-ndjson",
        },
        body,
    });
    if (!response.ok) {
        return new Response(`Elasticsearch gave status ${response.status}.\n`, {
            status: 502,
            headers: { "Cache-Control": "no-store" },
        });
    }

    // An index that does not exist gives an error. The response does not
    // include that index, and the caches do not keep the response.
    const { responses } = await response.json();
    const counts = {};
    let complete = true;
    responses.forEach((result, i) => {
        if (result.error) {
            complete = false;
            return;
        }
        counts[indexes[i]] = Object.fromEntries(
            result.aggregations.types.buckets.map((bucket) => [
                bucket.key,
                bucket.doc_count,
            ]),
        );
    });

    return Response.json(counts, {
        headers: complete
            ? {
                  "Cache-Control": `public, max-age=${ONE_DAY}`,
                  "Netlify-CDN-Cache-Control": `public, s-maxage=${ONE_DAY}, stale-while-revalidate=${ONE_DAY}`,
              }
            : { "Cache-Control": "no-store" },
    });
};

export const config = { path: "/counts", cache: "manual" };
