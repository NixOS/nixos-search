{ pkgs ? import <nixpkgs> { }
, version ? "0"
}:
let
  inherit (pkgs.poetry2nix) mkPoetryApplication overrides;
in
mkPoetryApplication {
  projectDir = ./.;
  overrides = overrides.withDefaults (self: super: {
    pypandoc = super.pypandoc.overridePythonAttrs (old: {
      postPatch = ''
        sed -i '/^__pandoc_path = None$/c__pandoc_path = "${pkgs.pandoc}/bin/pandoc"' pypandoc/__init__.py
      '';
    });
  });
  checkPhase = ''
    black --diff --check ./import_scripts
    flake8 --ignore W503,E501,E265,E203 ./import_scripts
  '';
  postInstall = ''
    wrapProgram $out/bin/import-channel --set INDEX_SCHEMA_VERSION "${version}"
  '';
}
