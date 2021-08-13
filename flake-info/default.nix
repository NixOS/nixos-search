{ pkgs ? import <nixpkgs> { } }: with pkgs;




rustPlatform.buildRustPackage rec {
    name = "flake-info";
    src = ./.;
    cargoSha256 = "sha256-qooAjbvdAcfBj5gm8kYbq1m8CZAcpz0KHROBV58lC+Q=";
    nativeBuildInputs = [ pkg-config ];
    buildInputs = [ openssl openssl.dev ] ++ lib.optional pkgs.stdenv.isDarwin [libiconv darwin.apple_sdk.frameworks.Security];
    checkFlags = [
        "--skip elastic::tests"
        "--skip nix_gc::tests"
    ];
}
