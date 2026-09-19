{ pkgs, ... }:
{
  projectRootFile = "flake.nix";

  programs = {
    nixfmt.enable = true;
    rustfmt.enable = true;
    elm-format.enable = true;

    # Python linter and formatter, configured in `ruff.toml`.
    ruff-check.enable = true;
    ruff-format.enable = true;

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
