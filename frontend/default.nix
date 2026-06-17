{
  buildNpmPackage,
  elm2nix,
  elmPackages,
  importNpmLock,
  nodejs,

  nixosChannels,
  version,
}:
let
  manifest = builtins.fromJSON (builtins.readFile ./package.json);
in buildNpmPackage {
  pname = manifest.name;
  version = manifest.version;
  src = ./.;
  installPhase = ''
    mkdir $out
    cp -R dist/* $out/
    cp netlify.toml $out/
  '';
  nativeBuildInputs =
    [
      nodejs
      elm2nix
    ]
    ++ (with elmPackages; [
      elm
      elm-format
      elm-language-server
      elm-test
    ]);

  postConfigure = elmPackages.fetchElmDeps {
    elmPackages = import ./elm-srcs.nix;
    elmVersion = elmPackages.elm.version;
    registryDat = ./registry.dat;
  };

  ELASTICSEARCH_MAPPING_SCHEMA_VERSION = version;
  NIXOS_CHANNELS = builtins.toJSON nixosChannels;

  npmBuildScript = "prod";
  npmDeps = importNpmLock {
    npmRoot = ./.;
    packageSourceOverrides = {
      "node_modules/elm" = elmPackages.elm;
    };
  };
  npmConfigHook = importNpmLock.npmConfigHook;
  npmFlags = [ "--legacy-peer-deps" ];
}
