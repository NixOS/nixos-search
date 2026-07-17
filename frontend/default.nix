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
    hash = "sha256-TNWedSteI3kwXHRpWek6nL9Rj9R2b252JceSnN5Jp5o=";
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

  npmBuildScript = "build";

  installPhase = ''
    runHook preInstall

    mkdir $out
    cp -R dist/* $out/
    cp netlify.toml $out/
    cp sitemap.xml $out/
    cp robots.txt $out/

    runHook postInstall
  '';
})
