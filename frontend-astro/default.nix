{
  lib,
  buildNpmPackage,
  importNpmLock,
  packageJSON ? lib.importJSON ./package.json,
  nixosChannels,
  version,
}:
buildNpmPackage (finalAttrs: {
  inherit (packageJSON) name;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.difference (lib.fileset.fromSource (lib.sources.cleanSource ./.)) ./default.nix;
  };

  npmDeps = importNpmLock {
    npmRoot = finalAttrs.src;
  };

  ELASTICSEARCH_MAPPING_SCHEMA_VERSION = version;
  NIXOS_CHANNELS = builtins.toJSON nixosChannels;

  npmConfigHook = importNpmLock.npmConfigHook;
  npmBuildScript = "build";

  passthru = {
    inherit packageJSON;
  };
})
