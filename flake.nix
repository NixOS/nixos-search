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
      allPackages = system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [
              poetry2nix.overlay
            ];
          };
          version = pkgs.lib.removeSuffix "\n" (builtins.readFile "${self}/VERSION");
        in
        {
          import_scripts = import ./import-scripts {
            inherit pkgs version;
          };
          frontend = import ./. {
            inherit pkgs version;
          };
        };
    in
    {
      packages = forAllSystems allPackages;
    };
}
