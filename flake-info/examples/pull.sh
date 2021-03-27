#! /usr/bin/env bash

# Run from cargo root as
# $ ./examples/pull.sh

echo "pulling examples in examples.txt"
examples=$(cat ./examples/examples.txt)
for flake in $examples; do

    cargo run -- --flake "$flake" | jq > examples/"$(echo "$flake" | tr "/" "-")".json

done

echo "pulling excamples using json file"
cargo run -- --targets ./examples/examples.in.json | jq > examples/adaspark-offen.json
