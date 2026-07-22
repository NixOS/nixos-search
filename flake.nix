{
  description = "Code behind search.nixos.org";

  nixConfig = {
    extra-substituters = [ "https://nixos-search.cachix.org" ];
    extra-trusted-public-keys = [
      "nixos-search.cachix.org-1:1HV3YF8az4fywnH+pAd+CXFEdpTXtv9WpoivPi+H70o="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # https://github.com/nix-community/npmlock2nix/blob/master/nix/sources.json
    nixos-infra.url = "github:NixOS/infra";
    nixos-infra.flake = false;
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      nixos-infra,
      treefmt-nix,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = nixpkgs.lib;
        treefmtEval = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;
        warnToUpgradeNix = lib.warn "Please upgrade Nix to 2.7 or later.";
        version = (import ./version.nix).frontend;
        nixosChannels =
          let
            allChannels = (import "${nixos-infra}/channels.nix").channels;
            filteredChannels = lib.filterAttrs (
              n: v:
              builtins.elem v.status [
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
              jobset = builtins.concatStringsSep "/" (lib.init (lib.splitString "/" v.job));
              branch = n;
            }) filteredChannels;
            default = builtins.head (
              builtins.sort (e1: e2: !(builtins.lessThan e1 e2)) (
                builtins.map (lib.removePrefix "nixos-") (
                  builtins.attrNames (lib.filterAttrs (_: v: v.status == "stable") filteredChannels)
                )
              )
            );
          };
        nixosChannelsFile = pkgs.runCommand "nixosChannels.json" { } ''
          echo '${builtins.toJSON (builtins.map (c: c.id) nixosChannels.channels)}' > $out
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
              export NIXOS_CHANNELS='${builtins.toJSON nixosChannels}';
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
          nixosChannelsJson = pkgs.writeText "nixosChannels.json" (builtins.toJSON nixosChannels);
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

        # XXX: for backwards compatibility
        devShell = warnToUpgradeNix devShells.default;
        defaultPackage = warnToUpgradeNix packages.default;

        apps.opensearch-vm = {
          type = "app";
          program = "${self.nixosConfigurations.opensearch-vm.config.system.build.vm}/bin/run-nixos-vm";
          meta.description = "Run OpenSearch on port 9200 in an ephemeral VM for local testing";
        };
      }
    )
    // {
      # Local testing VM configuration
      nixosConfigurations.opensearch-vm = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          (import "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix")
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
}
