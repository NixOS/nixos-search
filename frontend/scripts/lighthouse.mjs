#!/usr/bin/env node
/**
 * Lighthouse check
 *
 * Audits a build of the frontend, and fails if an audit does not pass. The
 * build comes from a local server, and the search results come from the
 * production backend.
 *
 * Usage:
 *   nix run .#lighthouse -- [--out <dir>]
 *
 * The HTML reports and `summary.md` go in `--out`.
 *
 * All audits are in `CATEGORIES`, except for the audits of the `performance`
 * category. The local server and a shared CI runner do not give stable
 * performance values.
 */

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import { createServer } from "node:http";
import { createRequire } from "node:module";
import { extname, join, resolve } from "node:path";
import { parseArgs } from "node:util";

const { values: args } = parseArgs({
    options: {
        dist: { type: "string" },
        out: { type: "string", default: "lighthouse-report" },
    },
});

// `NODE_PATH` holds these packages, which are not in `package-lock.json`.
// An `import` statement does not use `NODE_PATH`, but `require` does.
const require = createRequire(import.meta.url);
const { default: lighthouse } = await import(require.resolve("lighthouse"));
const { default: desktopConfig } = await import(
    require.resolve("lighthouse/core/config/desktop-config.js")
);
const { default: puppeteer } = await import(require.resolve("puppeteer-core"));

const CATEGORIES = ["accessibility", "best-practices", "seo"];
const COLOR_SCHEMES = ["light", "dark"];
const FORM_FACTORS = {
    mobile: undefined,
    desktop: desktopConfig,
};

// `selector` must match when the audit completes. The audits of an error page
// or an empty page can pass, thus a pass without this match has no value.
const PAGES = [
    {
        name: "packages-empty",
        path: "/packages",
        selector: ".search-page.not-asked",
    },
    {
        name: "packages-results",
        path: "/packages?query=firefox",
        selector: "#result-firefox",
    },
    {
        name: "packages-details",
        path: "/packages?show=firefox&query=firefox",
        selector: "#result-firefox .package-details",
    },
    {
        name: "options-results",
        path: "/options?query=boot.isContainer",
        selector: '[id="result-option:boot.isContainer"]',
    },
    {
        name: "options-details",
        path: "/options?show=option:boot.isContainer&query=boot.isContainer",
        selector: '[id="result-option:boot.isContainer"].opened',
    },
    {
        name: "flakes-results",
        path: "/flakes?query=nix",
        selector: "#result-nix",
    },
];

// `/backend` has the same target as in production. A build does not contain
// the images, thus they come from production too.
const IMAGES_URL = "https://search.nixos.org";
const backendUrl = readFileSync(join(args.dist, "_redirects"), "utf8").match(
    /^\/backend\/\*\s+(\S+?)\/?:splat/m,
)[1];

function upstreamUrl(url) {
    if (url.startsWith("/backend/")) {
        return backendUrl + url.slice("/backend".length);
    }
    if (url.startsWith("/icons/") || url.startsWith("/screenshots/")) {
        return IMAGES_URL + url;
    }
    return undefined;
}

const CONTENT_TYPES = {
    ".css": "text/css",
    ".html": "text/html",
    ".js": "text/javascript",
    ".json": "application/json",
    ".png": "image/png",
    ".svg": "image/svg+xml",
    ".txt": "text/plain",
    ".webp": "image/webp",
    ".woff2": "font/woff2",
    ".xml": "application/xml",
};

async function proxy(req, res, url) {
    const body = [];
    for await (const chunk of req) {
        body.push(chunk);
    }
    const upstream = await fetch(url, {
        method: req.method,
        headers: {
            authorization: req.headers.authorization,
            "content-type": req.headers["content-type"],
        },
        body: body.length > 0 ? Buffer.concat(body) : undefined,
    });
    res.writeHead(upstream.status, {
        "content-type": upstream.headers.get("content-type"),
    });
    res.end(Buffer.from(await upstream.arrayBuffer()));
}

// A path that is not a file gets `index.html`, as with `_redirects`.
async function serveFile(res, pathname) {
    const file = join(args.dist, pathname);
    const isFile = await stat(file).then(
        (s) => s.isFile(),
        () => false,
    );
    const path = isFile ? file : join(args.dist, "index.html");
    res.writeHead(200, {
        "content-type": CONTENT_TYPES[extname(path)] ?? "application/octet-stream",
    });
    res.end(await readFile(path));
}

function startServer() {
    const server = createServer((req, res) => {
        const url = upstreamUrl(req.url);
        const response = url
            ? proxy(req, res, url)
            : serveFile(res, new URL(req.url, "http://localhost").pathname);
        response.catch((error) => {
            console.error(`${req.url}: ${error}`);
            res.writeHead(502);
            res.end();
        });
    });
    return new Promise((done) => {
        server.listen(0, "127.0.0.1", () => done(server));
    });
}

function failedAudits(lhr) {
    const audits = CATEGORIES.flatMap((id) =>
        lhr.categories[id].auditRefs.map((ref) => lhr.audits[ref.id]),
    );
    return [...new Set(audits)]
        .filter(
            (audit) =>
                audit.scoreDisplayMode === "error" ||
                (["binary", "numeric"].includes(audit.scoreDisplayMode) &&
                    audit.score < 1),
        )
        .map((audit) => audit.id)
        .sort();
}

async function audit(browser, baseUrl, page, colorScheme, formFactor) {
    const tab = await browser.newPage();
    try {
        await tab.emulateMediaFeatures([
            { name: "prefers-color-scheme", value: colorScheme },
        ]);
        const { lhr, report } = await lighthouse(
            baseUrl + page.path,
            {
                disableFullPageScreenshot: true,
                logLevel: "error",
                onlyCategories: CATEGORIES,
                output: "html",
            },
            FORM_FACTORS[formFactor],
            tab,
        );
        writeFileSync(
            join(args.out, `${page.name}-${colorScheme}-${formFactor}.html`),
            report,
        );

        const failures = failedAudits(lhr);
        if (lhr.runtimeError) {
            failures.push(`runtime error: ${lhr.runtimeError.code}`);
        }
        if ((await tab.$(page.selector)) === null) {
            failures.push(`no match for ${page.selector}`);
        }
        const schemeApplied = await tab.evaluate(
            (scheme) =>
                window.matchMedia(`(prefers-color-scheme: ${scheme})`).matches,
            colorScheme,
        );
        if (!schemeApplied) {
            failures.push(`color scheme is not ${colorScheme}`);
        }
        return failures;
    } finally {
        await tab.close();
    }
}

mkdirSync(args.out, { recursive: true });
const server = await startServer();
const browser = await puppeteer.launch({
    executablePath: process.env.CHROME_PATH,
    // The AppArmor profile of a GitHub runner blocks the sandbox of Chromium.
    args: ["--no-sandbox"],
});

const rows = [];
try {
    const baseUrl = `http://127.0.0.1:${server.address().port}`;
    for (const page of PAGES) {
        for (const colorScheme of COLOR_SCHEMES) {
            for (const formFactor of Object.keys(FORM_FACTORS)) {
                const failures = await audit(
                    browser,
                    baseUrl,
                    page,
                    colorScheme,
                    formFactor,
                );
                console.log(
                    `${page.name} (${colorScheme}, ${formFactor}): ${failures.join(", ") || "pass"}`,
                );
                rows.push({ page, colorScheme, formFactor, failures });
            }
        }
    }
} finally {
    await browser.close();
    server.close();
}

const summary = [
    "# Lighthouse",
    "",
    "| Page | Color scheme | Form factor | Failures |",
    "| --- | --- | --- | --- |",
    ...rows.map(
        ({ page, colorScheme, formFactor, failures }) =>
            `| \`${page.path}\` | ${colorScheme} | ${formFactor} | ${failures.map((f) => `\`${f}\``).join(", ") || "none"} |`,
    ),
    "",
].join("\n");
writeFileSync(join(resolve(args.out), "summary.md"), summary);

process.exitCode = rows.some((row) => row.failures.length > 0) ? 1 : 0;
