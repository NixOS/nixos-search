{ pkgs ? import <nixpkgs> { }
, version ? pkgs.lib.removeSuffix "\n" (builtins.readFile ./../VERSION)
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
  preferLocalBuild = true;
  nativeBuildInputs = with pkgs; [
    poetry
    fd
    entr
    nixStable
  ];
  checkPhase = ''
    export PYTHONPATH=$PWD:$PYTHONPATH
    black --diff --check import_scripts/ tests/
    flake8 --ignore W503,E501,E265,E203 import_scripts/ tests/
    mypy import_scripts/ tests/
    pytest -vv tests/
  '';
  postInstall = ''
    wrapProgram $out/bin/import-channel \
      --set INDEX_SCHEMA_VERSION "${version}" \
      --prefix PATH : "${pkgs.nixStable}/bin"
    wrapProgram $out/bin/channel-diff \
      --set INDEX_SCHEMA_VERSION "${version}" \
      --prefix PATH : "${pkgs.nixStable}/bin"

  '';
  shellHook = ''
    cd import-scripts/
    export PYTHONPATH=$PWD:$PYTHONPATH
  '';
}
