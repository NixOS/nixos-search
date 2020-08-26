{
  description = "Code behind search.nixos.org";

  inputs = {
    nixpkgs = { url = "nixpkgs/nixos-unstable"; };
    poetry2nix = { url = "github:nix-community/poetry2nix"; };
    flake-utils = { url = "github:numtide/flake-utils"; };
  };

  outputs = { self, nixpkgs, poetry2nix, flake-utils }:
    flake-utils.lib.simpleFlake {
      name = "nixos-search";
      inherit self nixpkgs;
      systems = flake-utils.lib.defaultSystems;
      preOverlays = [
        poetry2nix.overlay
      ];
      overlay = ./overlay.nix;
      shell = ./.;
    };
}
