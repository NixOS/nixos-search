{ pkgs ? import <nixpkgs> {}
}:

let
in pkgs.stdenv.mkDerivation {
  name = "nixos-search";
  src = pkgs.lib.cleanSource ./.;

  buildInputs =
    (with pkgs; [
      nodejs
    ]) ++
    (with pkgs.nodePackages; [
      yarn
    ]) ++
    (with pkgs.elmPackages; [
      elm
      elm-format
    ]);

  shellHook = ''
    export PATH=$PWD/node_modules/.bin:$PATH
  '';

}
