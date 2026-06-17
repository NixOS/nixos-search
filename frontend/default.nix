{
  stdenvNoCC,
  fetchNpmDeps,
  elmPackages,
  nodejs,
  npmHooks,

  nixosChannels,
  version,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  name = "frontend";
  src = ./.;

  npmDeps = fetchNpmDeps {
    pname = "npm-deps-${finalAttrs.name}";
    inherit (finalAttrs) src;
    hash = "sha256-VTuxcAVvynniB1/XXXFdiymegfYBoKwS4lFHJ3I1ltA=";
  };

  postConfigure = elmPackages.fetchElmDeps {
    elmPackages = import ./elm-srcs.nix;
    elmVersion = elmPackages.elm.version;
    registryDat = ./registry.dat;
  };

  strictDeps = true;

  env = {
    ELASTICSEARCH_MAPPING_SCHEMA_VERSION = version;
    NIXOS_CHANNELS = builtins.toJSON nixosChannels;
  };

  nativeBuildInputs = [
    nodejs
    npmHooks.npmConfigHook
    npmHooks.npmBuildHook
    npmHooks.npmInstallHook
  ];

  npmBuildScript = "prod";

  installPhase = ''
    runHook preInstall

    mkdir $out
    cp -R dist/* $out/
    cp netlify.toml $out/

    runHook postInstall
  '';
})
