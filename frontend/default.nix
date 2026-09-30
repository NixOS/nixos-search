{
  lib,
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
    # The compiler that does the build is the one `package-lock.json` holds, not
    # the one `nixpkgs` has. `ELM_HOME` keeps a directory for each compiler
    # version, thus the packages must go in the directory of the npm compiler.
    elmVersion = lib.head (
      lib.splitString "-" (lib.importJSON ./package-lock.json).packages."node_modules/elm".version
    );
    registryDat = ./registry.dat;
  };

  strictDeps = true;

  env = {
    ELASTICSEARCH_MAPPING_SCHEMA_VERSION = version;
    NIXOS_CHANNELS = lib.toJSON nixosChannels;
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
