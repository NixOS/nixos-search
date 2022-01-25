{
  description = "Code behind search.nixos.org";

  nixConfig = {
    extra-substituters = [ "https://nixos-search.cachix.org" ];
    extra-trusted-public-keys = [ "nixos-search.cachix.org-1:1HV3YF8az4fywnH+pAd+CXFEdpTXtv9WpoivPi+H70o=" ];
  };

  inputs = {
    nixpkgs = { url = "nixpkgs/nixos-unstable"; };
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "i686-linux" "x86_64-darwin" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
      mkPackage = path: system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ ];
          };
        in
        import path { inherit pkgs; };
      packages = system:
        {
          flake-info = mkPackage ./flake-info system;
          frontend = mkPackage ./. system;
        };

      devShell = system:
        let
          packages_inst = (packages system);
          pkgs = nixpkgs.legacyPackages.${system};
        in
        pkgs.mkShell {
          inputsFrom = builtins.attrValues packages_inst;
          shellHook = ''
            export RUST_SRC_PATH="${pkgs.rustPlatform.rustLibSrc}";
            export NIXPKGS_PANDOC_FILTERS_PATH="${packages_inst.flake-info.NIXPKGS_PANDOC_FILTERS_PATH}";
          '';
        };
    in
    {
      defaultPackage = forAllSystems (mkPackage ./.);
      packages = forAllSystems packages;
      devShell = forAllSystems devShell;
    };
}
