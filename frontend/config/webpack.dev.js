const path = require("path");

const { merge } = require("webpack-merge");
const common = require("./webpack.common.js");

const dev = {
    mode: "development",
    devServer: {
        hot: "only",
        client: {
            logging: "info",
        },
        static: { directory: path.join(__dirname, "../src/assets") },
        devMiddleware: {
            publicPath: "/",
            stats: "errors-only",
        },
        historyApiFallback: true,
        proxy: {
            "/backend": {
                target: "https://nixos-search-7-1733963800.us-east-1.bonsaisearch.net/",
                pathRewrite: { "^/backend": "" },
                changeOrigin: true,
            },
        },
    },
};

module.exports = (env) => {
    const withDebug = !env.nodebug;
    return merge(common(withDebug, false), dev);
};
