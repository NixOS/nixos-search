{
  description = "Code behind search.nixos.org";

  nixConfig.extra-substituters = [ "https://nixos-search.cachix.org" ];
  nixConfig.extra-trusted-public-keys = [ "nixos-search.cachix.org-1:1HV3YF8az4fywnH+pAd+CXFEdpTXtv9WpoivPi+H70o=" ];

  # TODO: follow nixos-unstable once elm-format fix is merged and release 
  #       on nixos-unstable channels:
  #         https://github.com/NixOS/nixpkgs/pull/167642
  # inputs.nixpkgs.url = "nixpkgs/nixos-unstable";
  inputs.nixpkgs.url = "github:aforemny/nixpkgs/fix/elm-format";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.nixos-org-configurations.url = "github:NixOS/nixos-org-configurations";
  inputs.nixos-org-configurations.flake = false;

  outputs = { self
            , nixpkgs
            , flake-utils
            , nixos-org-configurations 
            }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          warnToUpgradeNix = pkgs.lib.warn "Please upgrade Nix to 2.7 or later.";
          version = pkgs.lib.removeSuffix "\n" (builtins.readFile ./VERSION);
          nixosChannels =
            let
              allChannels = (import "${nixos-org-configurations}/channels.nix").channels;
              filteredChannels =
                pkgs.lib.filterAttrs
                  (n: v:
                    builtins.elem v.status ["beta" "stable" "rolling"] &&
                    pkgs.lib.hasPrefix "nixos-" n &&
                    v ? variant && v.variant == "primary"
                  )
                  allChannels;
            in
            {
              channels =
                builtins.map
                  (n: let v = filteredChannels.${n}; in
                    {
                      id = pkgs.lib.removePrefix "nixos-" n;
                      status = v.status;
                      jobset =
                        builtins.concatStringsSep
                          "/"
                          (pkgs.lib.init (pkgs.lib.splitString "/" v.job));
                      branch = n;
                    }
                  )
                  (builtins.attrNames filteredChannels);
              default =
                builtins.head
                  (builtins.sort (e1: e2: ! (builtins.lessThan e1 e2))
                    (builtins.map
                      (pkgs.lib.removePrefix "nixos-")
                      (builtins.attrNames
                        (pkgs.lib.filterAttrs (_: v: v.status == "stable") filteredChannels)
                      )
                    )
                  );
            };
          nixosChannelsFile = pkgs.runCommand "nixosChannels.json" {} ''
            echo '${builtins.toJSON (builtins.map (c: c.id) nixosChannels.channels)}' > $out
          '';
        in rec {

          packages.default = packages.flake-info;
          packages.flake-info = import ./flake-info { inherit pkgs nixosChannels; };
          packages.frontend = import ./frontend { inherit pkgs nixosChannels version; };
          packages.nixosChannels = nixosChannelsFile;

          devShells.default = pkgs.mkShell {
            inputsFrom = builtins.attrValues packages;
            shellHook = ''
              export RUST_SRC_PATH="${pkgs.rustPlatform.rustLibSrc}";
              export NIXPKGS_PANDOC_FILTERS_PATH="${packages.flake-info.NIXPKGS_PANDOC_FILTERS_PATH}";
              export NIXOS_CHANNELS='${builtins.toJSON nixosChannels}';
              export ELASTICSEARCH_MAPPING_SCHEMA_VERSION="${version}";
              export PATH=$PWD/frontend/node_modules/.bin:$PATH

              rm -rf frontend/node_modules
              ln -sf ${packages.frontend.yarnPkg}/libexec/${(builtins.parseDrvName packages.frontend.name).name}/node_modules frontend/
              echo "========================================================"
              echo "= To develop the frontend run: cd frontend && yarn dev ="
              echo "========================================================"
            '';
          };

          # XXX: for backwards compatibility
          devShell = warnToUpgradeNix devShells.default;
          defaultPackage = warnToUpgradeNix packages.default;
        }
      );
}
