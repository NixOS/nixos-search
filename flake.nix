{
  description = "Code behind search.nixos.org";

  nixConfig.extra-substituters = [ "https://nixos-search.cachix.org" ];
  nixConfig.extra-trusted-public-keys = [ "nixos-search.cachix.org-1:1HV3YF8az4fywnH+pAd+CXFEdpTXtv9WpoivPi+H70o=" ];

  inputs.nixpkgs.url = "nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self
            , nixpkgs
            , flake-utils
            }:
    flake-utils.lib.eachSystem
      (with flake-utils.lib.system; [
        x86_64-linux
        i686-linux
        x86_64-darwin
        aarch64-linux
      ])
      (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          warnToUpgradeNix = pkgs.lib.warn "Please upgrade Nix to 2.7 or later.";
        in rec {

          packages.default = packages.flake-info;
          packages.flake-info = import ./flake-info { inherit pkgs; };
          packages.frontend = import ./frontend { inherit pkgs; };

          devShells.default = pkgs.mkShell {
            inputsFrom = builtins.attrValues packages;
            shellHook = ''
              export RUST_SRC_PATH="${pkgs.rustPlatform.rustLibSrc}";
              export NIXPKGS_PANDOC_FILTERS_PATH="${packages.flake-info.NIXPKGS_PANDOC_FILTERS_PATH}";
            '';
          };

          # XXX: for backwards compatibility
          devShell = warnToUpgradeNix devShells.default;
          defaultPackage = warnToUpgradeNix packages.default;
        }
      );
}
