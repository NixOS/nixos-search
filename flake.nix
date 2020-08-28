{
  description = "Code behind search.nixos.org";

  inputs = {
    nixpkgs = { url = "nixpkgs/nixos-unstable"; };
    poetry2nix = { url = "github:nix-community/poetry2nix"; };
  };

  outputs = { self, nixpkgs, poetry2nix }:
    let
      systems = [ "x86_64-linux" "i686-linux" "x86_64-darwin" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
      mkPackage = path: system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ poetry2nix.overlay ];
          };
        in
          import path { inherit pkgs; };
      packages = system:
        {
          import_scripts = mkPackage ./import-scripts system;
          frontend = mkPackage ./. system;
        };
    in
    {
      defaultPackage = forAllSystems (mkPackage ./.);
      packages = forAllSystems packages;
    };
}
