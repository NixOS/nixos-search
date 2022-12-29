const {merge} = require('webpack-merge');

const CopyWebpackPlugin = require("copy-webpack-plugin");
// JS minification
const TerserPlugin = require("terser-webpack-plugin");
// Production CSS assets - separate, minimised file
const MiniCssExtractPlugin = require("mini-css-extract-plugin");
const CssMinimizerPlugin = require("css-minimizer-webpack-plugin");

const common = require('./webpack.common.js');

const prod = {
    mode: 'production',
    optimization: {
        minimize: true,
        minimizer: [
            new TerserPlugin(),
            new CssMinimizerPlugin(),
        ]
    },
    plugins: [
        // Copy static assets
        new CopyWebpackPlugin({
            patterns: [{from: "src/assets"}]
        }),
        new MiniCssExtractPlugin({
            // Options similar to the same options in webpackOptions.output
            filename: "[name]-[chunkhash].css"
        })
    ],
    module: {
        rules: [
            {
                test: /\.elm$/,
                use: {
                    loader: "elm-webpack-loader",
                    options: {
                        optimize: true
                    }
                }
            },
            {
                test: /\.(sa|sc|c)ss$/i,
                use: [
                    MiniCssExtractPlugin.loader,
                    "css-loader",
                    {
                        loader: "postcss-loader",
                        options: {
                            postcssOptions: {
                                plugins: [
                                    require("autoprefixer"),
                                ],
                            },
                        }
                    }, "sass-loader"
                ]
            }
        ]
    }

};

module.exports = merge(common(false), prod);
