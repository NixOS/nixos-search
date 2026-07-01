import { defineConfig } from "@rsbuild/core";
import { pluginSass } from "@rsbuild/plugin-sass";
import * as sass from "sass";

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
            { from: "./src/assets", to: "." },
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
        rspack: (config, { env }) => {
            const isProd = env === "production";
            const withDebug = process.env.NODEBUG !== "true" && !isProd;

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
