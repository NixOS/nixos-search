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
    nix-unit = {
      url = "github:nix-community/nix-unit";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.treefmt-nix.follows = "treefmt-nix";
    };
    namaka = {
      url = "github:nix-community/namaka";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    services-flake.url = "github:juspay/services-flake";
    process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
  };

  outputs =
    inputs@{
      flake-parts,
      nix-unit,
      namaka,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.nix-unit.modules.flake.default
        inputs.process-compose-flake.flakeModule
      ];
      systems = import inputs.systems;

      flake = {
        lib = {
          evalFlake =
            { targetFlake }:
            import ./flake-info/assets/commands/evalFlake.nix {
              inherit targetFlake;
              nixpkgsFlake = inputs.nixpkgs;
              flake-schemas = inputs.flake-schemas;
            };
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
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            config.allowUnfree = true; # required for elasticsearch7
          };

          nix-unit.inputs = {
            inherit (inputs) nixpkgs flake-parts nix-unit;
          };

          packages = {
            default = packages.flake-info;
            flake-info = import ./flake-info {
              inherit pkgs;
              inherit (inputs) self;
            };
            frontend = pkgs.callPackage ./frontend {
              inherit nixosChannels version;
            };
            nixosChannels = nixosChannelsFile;
            nixosChannelsJson = pkgs.writeText "nixosChannels.json" (lib.toJSON nixosChannels);
          };

          checks = namaka.lib.load {
            src = ./flake-info/assets/commands/test;
            inputs = {
              evalTarget = targetFlake: {
                expr = (inputs.self.lib.evalFlake { inherit targetFlake; }).evalFlake;
              };
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
                rustfmt
                rust-analyzer
                inputs.nix-unit.packages.${system}.default
                inputs.namaka.packages.${system}.default
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

          process-compose.services = {
            imports = [
              inputs.services-flake.processComposeModules.default
            ];
            services.elasticsearch."dev".enable = true; # use elasticsearch7 by default as of 2026-08-03, the same as prod (also see https://github.com/juspay/services-flake/issues/712)
          };
        };
    };
}
