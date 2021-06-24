{ pkgs ? import <nixpkgs> { } }: with pkgs;




rustPlatform.buildRustPackage rec {
    name = "flake-info";
    src = ./.;
    cargoSha256 = "sha256-mrk5kHU/BGuij9ZrscgZolKDfWzFWfb9Ws4STl2VHpk=";
    buildInputs = [ ] ++ lib.optional pkgs.stdenv.isDarwin [libiconv darwin.apple_sdk.frameworks.Security];
    checkFlags = [
        "--skip elastic::tests"
        "--skip nix_gc::tests"
    ];
}
