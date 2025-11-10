{ pkgs ? import <nixpkgs> { }
, nixosChannels
, version
}:
pkgs.npmlock2nix.v1.build {
  src = ./.;
  installPhase = ''
    mkdir $out
    cp -R dist/* $out/
    cp netlify.toml $out/
  '';
  postConfigure = pkgs.elmPackages.fetchElmDeps {
    elmPackages = import ./elm-srcs.nix;
    elmVersion = pkgs.elmPackages.elm.version;
    registryDat = ./registry.dat;
  };
  ELASTICSEARCH_MAPPING_SCHEMA_VERSION = version;
  NIXOS_CHANNELS = builtins.toJSON nixosChannels;
  buildCommands = [
    "HOME=$PWD npm run prod"
  ];
  buildInputs =
    (with pkgs; [
      nodejs
      elm2nix
    ]) ++
    (with pkgs.elmPackages; [
      elm
      elm-format
      elm-language-server
      elm-test
    ]);
  node_modules_attrs = {
    sourceOverrides = {
      elm = sourceIngo: drv: drv.overrideAttrs (old: {
        postPatch = ''
          sed -i -e "s|download(|//download(|" install.js
          sed -i -e "s|request(|//request(|" download.js
          sed -i -e "s|var version|return; var version|" download.js
          cp ${pkgs.elmPackages.elm}/bin/elm bin/elm
        '';
      });
    };
  };
}
