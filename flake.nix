{
  description = "Code behind search.nixos.org";

  nixConfig.extra-substituters = [ "https://nixos-search.cachix.org" ];
  nixConfig.extra-trusted-public-keys = [ "nixos-search.cachix.org-1:1HV3YF8az4fywnH+pAd+CXFEdpTXtv9WpoivPi+H70o=" ];

  inputs.nixpkgs.url = "nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.npmlock2nix.url = "github:nix-community/npmlock2nix";
  inputs.npmlock2nix.flake = false;
  inputs.nixos-org-configurations.url = "github:NixOS/nixos-org-configurations";
  inputs.nixos-org-configurations.flake = false;

  outputs = { self
            , nixpkgs
            , flake-utils
            , npmlock2nix
            , nixos-org-configurations
            }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [
              (self: super: {
                npmlock2nix = super.callPackage npmlock2nix {};
              })
            ];
          };
          lib = nixpkgs.lib;
          warnToUpgradeNix = lib.warn "Please upgrade Nix to 2.7 or later.";
          version = lib.fileContents ./VERSION;
          nixosChannels =
            let
              allChannels = (import "${nixos-org-configurations}/channels.nix").channels;
              filteredChannels =
                lib.filterAttrs
                  (n: v:
                    builtins.elem v.status ["rolling" "beta" "stable" "deprecated"] &&
                    lib.hasPrefix "nixos-" n &&
                    v ? variant && v.variant == "primary"
                  )
                  allChannels;
            in
            {
              channels =
                lib.mapAttrsToList
                  (n: v:
                    {
                      id = lib.removePrefix "nixos-" n;
                      status = v.status;
                      jobset =
                        builtins.concatStringsSep
                          "/"
                          (lib.init (lib.splitString "/" v.job));
                      branch = n;
                    }
                  )
                  filteredChannels;
              default =
                builtins.head
                  (builtins.sort (e1: e2: ! (builtins.lessThan e1 e2))
                    (builtins.map
                      (lib.removePrefix "nixos-")
                      (builtins.attrNames
                        (lib.filterAttrs (_: v: v.status == "stable") filteredChannels)
                      )
                    )
                  );
            };
          nixosChannelsFile = pkgs.runCommand "nixosChannels.json" {} ''
            echo '${builtins.toJSON (builtins.map (c: c.id) nixosChannels.channels)}' > $out
          '';

          mkDevShell = { inputsFrom ? [], extraPackages ? [], extraShellHook ? "" }:
            pkgs.mkShell {
              inherit inputsFrom;
              packages = extraPackages;
              shellHook = ''
                export NIXOS_CHANNELS='${builtins.toJSON nixosChannels}';
                export ELASTICSEARCH_MAPPING_SCHEMA_VERSION="${version}";
              '' + extraShellHook;
            };
        in rec {

          packages.default = packages.flake-info;
          packages.flake-info = import ./flake-info { inherit pkgs nixosChannels; };
          packages.frontend = import ./frontend { inherit pkgs nixosChannels version; };
          packages.nixosChannels = nixosChannelsFile;

          devShells.default = mkDevShell {
            inputsFrom = [
              packages.flake-info
              packages.frontend
            ];
            extraPackages = [
              pkgs.rustfmt
              pkgs.yarn
            ];
            extraShellHook = ''
              export RUST_SRC_PATH="${pkgs.rustPlatform.rustLibSrc}";
              export NIXPKGS_PANDOC_FILTERS_PATH="${packages.flake-info.NIXPKGS_PANDOC_FILTERS_PATH}";
              export PATH=$PWD/frontend/node_modules/.bin:$PATH
            '';
          };

          devShells.flake-info = mkDevShell {
            inputsFrom = [packages.flake-info];
            extraPackages = [pkgs.rustfmt];
            extraShellHook = ''
              export RUST_SRC_PATH="${pkgs.rustPlatform.rustLibSrc}";
              export NIXPKGS_PANDOC_FILTERS_PATH="${packages.flake-info.NIXPKGS_PANDOC_FILTERS_PATH}";
            '';
          };

          devShells.frontend = mkDevShell {
            inputsFrom = [packages.frontend] ;
            extraPackages = [pkgs.rustfmt pkgs.yarn];
            extraShellHook = ''
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
