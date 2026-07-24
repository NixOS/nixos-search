{
  description = "Code behind search.nixos.org";

  nixConfig = {
    extra-substituters = [ "https://nixos-search.cachix.org" ];
    extra-trusted-public-keys = [
      "nixos-search.cachix.org-1:1HV3YF8az4fywnH+pAd+CXFEdpTXtv9WpoivPi+H70o="
    ];
  };

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    systems = {
      url = "github:nix-systems/default";
      flake = false;
    };
    # https://github.com/nix-community/npmlock2nix/blob/master/nix/sources.json
    nixos-infra = {
      url = "github:NixOS/infra";
      flake = false;
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-schemas.url = "github:DeterminateSystems/flake-schemas";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      flake = {
        lib = {
          evalFlake =
            {
              targetFlake,
              targetFlakeUri ? null,
            }:
            import ./flake-info/assets/commands/flake_info.nix {
              inherit targetFlake targetFlakeUri;
              nixpkgsFlake = inputs.nixpkgs;
              flake-schemas = inputs.flake-schemas;
            };
        };

        # Local testing VM configuration
        nixosConfigurations.opensearch-vm = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            (import "${inputs.nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix")
            (
              { lib, pkgs, ... }:
              {
                system.stateVersion = "25.05";
                services.getty.autologinUser = "root";
                virtualisation = {
                  diskImage = null; # makes VM ephemeral
                  graphics = false;
                  forwardPorts = [
                    {
                      guest.port = 9200;
                      host.port = 9200;
                    }
                  ]; # expose :9200 from guest to host
                  memorySize = 1024 * 8; # 8 GB
                };
                environment.systemPackages = with pkgs; [ opensearch-cli ];
                networking.firewall.allowedTCPPorts = [ 9200 ];
                services.opensearch = {
                  enable = true;
                  settings = {
                    "network.host" = "0.0.0.0";
                    "http.cors.enabled" = "true";
                    "http.cors.allow-origin" = "http://localhost:3000";
                    "http.cors.allow-credentials" = "true";
                    "http.cors.allow-headers" =
                      "X-Requested-With,X-Auth-Token,Content-Type,Content-Length,Authorization";
                  };
                };
              }
            )
          ];
        };
      };

      perSystem =
        {
          pkgs,
          system,
          lib,
          ...
        }:
        let
          treefmtEval = inputs.treefmt-nix.lib.evalModule pkgs ./treefmt.nix;
          version = (import ./version.nix).frontend;
          nixosChannels =
            let
              allChannels = (import "${inputs.nixos-infra}/channels.nix").channels;
              filteredChannels = lib.filterAttrs (
                n: v:
                lib.elem v.status [
                  "rolling"
                  "beta"
                  "stable"
                  "deprecated"
                ]
                && lib.hasPrefix "nixos-" n
                && v ? variant
                && v.variant == "primary"
              ) allChannels;
            in
            {
              channels = lib.mapAttrsToList (n: v: {
                id = lib.removePrefix "nixos-" n;
                status = v.status;
                jobset = lib.concatStringsSep "/" (lib.init (lib.splitString "/" v.job));
                branch = n;
              }) filteredChannels;
              default = lib.head (
                lib.sort (e1: e2: e1 > e2) (
                  map (lib.removePrefix "nixos-") (
                    lib.attrNames (lib.filterAttrs (_: v: v.status == "stable") filteredChannels)
                  )
                )
              );
            };
          nixosChannelsFile = pkgs.runCommand "nixosChannels.json" { } ''
            echo '${lib.toJSON (map (c: c.id) nixosChannels.channels)}' > $out
          '';

          treefmt = treefmtEval.config.build.wrapper;

          mkDevShell =
            {
              inputsFrom ? [ ],
              extraPackages ? [ ],
              extraShellHook ? "",
            }:
            pkgs.mkShell {
              inherit inputsFrom;
              packages = [ treefmt ] ++ extraPackages;
              shellHook = ''
                export NIXOS_CHANNELS='${lib.toJSON nixosChannels}';
                export ELASTICSEARCH_MAPPING_SCHEMA_VERSION="${version}";
              ''
              + extraShellHook;
            };
        in
        rec {
          packages = {
            default = packages.flake-info;
            flake-info = import ./flake-info { inherit pkgs; };
            frontend = pkgs.callPackage ./frontend {
              inherit nixosChannels version;
            };
            nixosChannels = nixosChannelsFile;
            nixosChannelsJson = pkgs.writeText "nixosChannels.json" (lib.toJSON nixosChannels);
          };

          checks = {
            flake-info = import ./flake-info/assets/commands/test {
              inherit pkgs;
              inherit (inputs) flake-schemas;
            };
          };

          formatter = treefmt;

          devShells = {
            default = mkDevShell {
              inputsFrom = [
                packages.flake-info
                packages.frontend
              ];
              extraPackages = with pkgs; [
                opensearch-cli
                rustfmt
                rust-analyzer
              ];
              extraShellHook = ''
                export RUST_SRC_PATH="${pkgs.rustPlatform.rustLibSrc}";
                export LINK_MANPAGES_PANDOC_FILTER="${packages.flake-info.LINK_MANPAGES_PANDOC_FILTER}";
                export PATH=$PWD/frontend/node_modules/.bin:$PATH
              '';
            };

            flake-info = mkDevShell {
              inputsFrom = [ packages.flake-info ];
              extraPackages = with pkgs; [
                rustfmt
                rust-analyzer
              ];
              extraShellHook = ''
                export RUST_SRC_PATH="${pkgs.rustPlatform.rustLibSrc}";
                export LINK_MANPAGES_PANDOC_FILTER="${packages.flake-info.LINK_MANPAGES_PANDOC_FILTER}";
              '';
            };

            frontend = mkDevShell {
              inputsFrom = [ packages.frontend ];
              extraPackages = with pkgs; [
                rustfmt
              ];
              extraShellHook = ''
                export PATH=$PWD/frontend/node_modules/.bin:$PATH
                echo "==========================================================="
                echo "= To develop the frontend run:                            ="
                echo "=   cd frontend && npm ci && npm run dev                   ="
                echo "==========================================================="
              '';
            };
          };

          apps.opensearch-vm = {
            type = "app";
            program = "${inputs.self.nixosConfigurations.opensearch-vm.config.system.build.vm}/bin/run-nixos-vm";
            meta.description = "Run OpenSearch on port 9200 in an ephemeral VM for local testing";
          };
        };
    };
}
