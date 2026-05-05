{
  pkgs ? import <nixpkgs> { },
  nixosChannels,
  version,
  elasticsearchUrl ? "https://nixos-search-7-1733963800.us-east-1.bonsaisearch.net",
  elasticsearchUsername ? "aWVSALXpZv",
  elasticsearchPassword ? "X8gPHnzL52wFEekuxsfQ9cSh",
}:
let
  # One JSON file per (category, channel) pair, served at
  # /autocomplete/<category>-<channel>.json.
  # Each file is an array of { name, description? } objects.
  # Falls back to [] if ES is unreachable so the build never fails.
  autocompleteAssets =
    pkgs.runCommand "autocomplete-assets"
      {
        __impure = true;
        nativeBuildInputs = [
          pkgs.curl
          pkgs.jq
        ];
        ELASTICSEARCH_URL = elasticsearchUrl;
        ELASTICSEARCH_USERNAME = elasticsearchUsername;
        ELASTICSEARCH_PASSWORD = elasticsearchPassword;
        ELASTICSEARCH_MAPPING_SCHEMA_VERSION = version;
        NIXOS_CHANNELS_JSON = builtins.toJSON nixosChannels.channels;
      }
      ''
        mkdir -p $out

        fetch_corpus() {
          local category="$1"
          local doc_type="$2"
          local channel_id="$3"
          local branch="$4"
          local out_file="$out/''${category}-''${channel_id}.json"

          local index="latest-''${ELASTICSEARCH_MAPPING_SCHEMA_VERSION}-''${branch}"
          local auth="''${ELASTICSEARCH_USERNAME}:''${ELASTICSEARCH_PASSWORD}"

          local body
          body=$(cat <<ESJSON
        {
          "from": 0,
          "size": 10000,
          "_source": ["option_name"],
          "query": {
            "bool": {
              "filter": [{ "term": { "type": "$doc_type" } }]
            }
          }
        }
        ESJSON
        )

          local response
          response=$(curl -sf --max-time 30 \
            -u "$auth" \
            -H "Content-Type: application/json" \
            -d "$body" \
            "''${ELASTICSEARCH_URL}/''${index}/_search" 2>/dev/null) || response=""

          if [ -n "$response" ]; then
            echo "$response" \
              | jq '[.hits.hits[]._source | {name: .option_name}]' \
              > "$out_file" 2>/dev/null \
              || echo "[]" > "$out_file"
          else
            echo "[]" > "$out_file"
          fi
        }

        echo "$NIXOS_CHANNELS_JSON" | jq -r '.[] | [.id, .branch] | @tsv' | \
        while IFS=$'\t' read -r channel_id branch; do
          fetch_corpus "services" "service" "$channel_id" "$branch"
          fetch_corpus "hm" "home-manager-option" "$channel_id" "$branch"
        done
      '';
in
pkgs.npmlock2nix.v1.build {
  src = ./.;
  installPhase = ''
    mkdir $out
    cp -R dist/* $out/
    cp netlify.toml $out/
    mkdir -p $out/autocomplete
    cp ${autocompleteAssets}/* $out/autocomplete/
  '';
  postConfigure = pkgs.elmPackages.fetchElmDeps {
    elmPackages = import ./elm-srcs.nix;
    elmVersion = pkgs.elmPackages.elm.version;
    registryDat = ./registry.dat;
  };
  ELASTICSEARCH_MAPPING_SCHEMA_VERSION = version;
  NIXOS_CHANNELS = builtins.toJSON nixosChannels;
  buildCommands = [
    "HOME=$PWD npm run prod"
  ];
  buildInputs =
    (with pkgs; [
      nodejs
      elm2nix
    ])
    ++ (with pkgs.elmPackages; [
      elm
      elm-format
      elm-language-server
      elm-test
    ]);
  node_modules_attrs = {
    sourceOverrides = {
      elm =
        sourceIngo: drv:
        drv.overrideAttrs (old: {
          postPatch = ''
            sed -i -e "s|download(|//download(|" install.js
            sed -i -e "s|request(|//request(|" download.js
            sed -i -e "s|var version|return; var version|" download.js
            cp ${pkgs.elmPackages.elm}/bin/elm bin/elm
          '';
        });
    };
  };
}
