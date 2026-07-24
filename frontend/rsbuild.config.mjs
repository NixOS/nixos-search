import { defineConfig } from "@rsbuild/core";
import { pluginSass } from "@rsbuild/plugin-sass";
import * as sass from "sass";

const FAVICON_PATH = "/images/nixos-logomark-default-gradient-none.svg";

const generateOpenSearchXml = (type, title, description) => `<?xml version="1.0"?>
<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/"
                       xmlns:moz="http://www.mozilla.org/2006/browser/search/">
  <ShortName>${title}</ShortName>
  <Description>${description}</Description>
  <Tags>nix nixos ${type}</Tags>
  <Developer>NixOS Community</Developer>
  <InputEncoding>UTF-8</InputEncoding>
  <Image width="16" height="16" type="image/svg+xml">${FAVICON_PATH}</Image>
  <Url type="text/html" template="https://search.nixos.org/${type}?query={searchTerms}"/>
  <moz:SearchForm>https://search.nixos.org/${type}</moz:SearchForm>
</OpenSearchDescription>
`;

export default defineConfig({
    plugins: [
        pluginSass({
            sassLoaderOptions: {
                implementation: sass,
            },
        }),
    ],
    source: {
        entry: {
            index: "./src/index.js",
        },
        define: {
            "process.env.ELASTICSEARCH_MAPPING_SCHEMA_VERSION": JSON.stringify(
                process.env.ELASTICSEARCH_MAPPING_SCHEMA_VERSION || "0",
            ),
            "process.env.ELASTICSEARCH_PASSWORD": JSON.stringify(
                process.env.ELASTICSEARCH_PASSWORD || "X8gPHnzL52wFEekuxsfQ9cSh",
            ),
            "process.env.ELASTICSEARCH_URL": JSON.stringify(
                process.env.ELASTICSEARCH_URL || "/backend",
            ),
            "process.env.ELASTICSEARCH_USERNAME": JSON.stringify(
                process.env.ELASTICSEARCH_USERNAME || "aWVSALXpZv",
            ),
            "process.env.NIXOS_CHANNELS": JSON.stringify(
                process.env.NIXOS_CHANNELS || "0",
            ),
        },
    },
    html: {
        template: "./src/index.html",
    },
    resolve: {
        extensions: [".elm", ".js"],
    },
    output: {
        copy: [
            {
                from: "node_modules/@nixos/branding/artifacts/internal",
                to: "images",
            },
        ],
    },
    server: {
        port: 3000,
        proxy: {
            "/backend": {
                target: "https://nixos-search-7-1733963800.us-east-1.bonsaisearch.net/",
                pathRewrite: { "^/backend": "" },
                changeOrigin: true,
            },
        },
    },
    tools: {
        rspack: (config, { env, rspack }) => {
            const isProd = env === "production";
            const withDebug = process.env.NODEBUG !== "true" && !isProd;

            config.plugins.push({
                apply(compiler) {
                    compiler.hooks.compilation.tap("OpenSearchPlugin", (compilation) => {
                        const manifests = [
                            ["opensearch-packages.xml", "packages", "NixOS: Search - Packages", "Search NixOS packages by name or description."],
                            ["opensearch-options.xml", "options", "NixOS: Search - Options", "Search NixOS configuration options."],
                            ["opensearch-flakes.xml", "flakes", "NixOS: Search - Flakes", "Search Nix ecosystem flakes."],
                        ];

                        for (const [filename, type, title, desc] of manifests) {
                            compilation.emitAsset(
                                filename,
                                new rspack.sources.RawSource(generateOpenSearchXml(type, title, desc))
                            );
                        }
                    });
                },
            });

            const elmLoaders = [];
            if (!isProd) {
                elmLoaders.push({ loader: "elm-reloader" });
            }
            elmLoaders.push({
                loader: "elm-webpack-loader",
                options: {
                    debug: withDebug,
                    optimize: isProd,
                },
            });

            config.module.rules.push({
                test: /\.elm$/,
                exclude: [/elm-stuff/, /node_modules/],
                use: elmLoaders,
            });
        },
    },
});
