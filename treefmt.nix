{ pkgs, ... }:
{
  projectRootFile = "flake.nix";

  programs = {
    nixpkgs-fmt.enable = true;
    rustfmt.enable = true;
    elm-format.enable = true;

    # JavaScript/JSON/Markdown formatter
    prettier = {
      enable = true;
      includes = [
        "*.js"
        "*.json"
        "*.md"
      ];
      excludes = [
        "frontend/node_modules/**"
        "flake-info/examples/*"
        "flake.lock"
        "frontend/package-lock.json"
      ];
    };
  };
}
