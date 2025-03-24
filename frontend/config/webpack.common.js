
const path = require('path');

const webpack = require("webpack");
const HtmlWebpackPlugin = require('html-webpack-plugin');
const {CleanWebpackPlugin} = require('clean-webpack-plugin');


module.exports = (withDebug, optimize) => {
    return {
        entry: './src/index.js',
        output: {
            path: path.resolve(__dirname, '../dist'),
            filename: 'bundle.js'
        },
        resolve: {
            modules: [path.join(__dirname, "../src"), 'node_modules'],
            extensions: [".elm", ".js"]
        },
        plugins: [
            new HtmlWebpackPlugin({
                template: "./src/index.html"
            }),
            new CleanWebpackPlugin(),
            new webpack.EnvironmentPlugin({
                ELASTICSEARCH_MAPPING_SCHEMA_VERSION: "0",
                ELASTICSEARCH_PASSWORD: 'X8gPHnzL52wFEekuxsfQ9cSh',
                ELASTICSEARCH_URL: '/backend',
                ELASTICSEARCH_USERNAME: 'aWVSALXpZv',
                NIXOS_CHANNELS: "0",
            }),
        ],
        optimization: {
            // Prevents compilation errors causing the hot loader to lose state
            emitOnErrors: false
        },
        module: {
            rules: [
                {
                    test: /\.elm$/,
                    use: [
                        {loader: "elm-reloader"},
                        {
                            loader: "elm-webpack-loader",
                            options: {
                                // add Elm's debug overlay to output
                                debug: withDebug,
                                optimize: optimize,
                            }
                        }
                    ]
                }, {
                    test: /\.(sa|sc|c)ss$/i,
                    use: ['style-loader', 'css-loader', {
                        loader: "postcss-loader",
                        options: {
                            postcssOptions: {
                                plugins: [
                                    require("autoprefixer"),
                                ],
                            },
                        }
                    }, "sass-loader"],
                }, {
                    test: /\.js$/,
                    exclude: /node_modules/,
                    use: {
                        loader: "babel-loader"
                    }
                },
                {
                    test: /\.(png|svg|jpg|jpeg|gif)$/i,
                    type: 'asset/resource',
                },
            ],
        }
    };
};
