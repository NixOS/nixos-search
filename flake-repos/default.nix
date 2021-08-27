{ pkgs ? import <nixpkgs> { } }:
with pkgs;

rustPlatform.buildRustPackage {
  name = "flake-repos";
  src = ./.;

  cargoLock = { lockFile = ./Cargo.lock; };

  nativeBuildInputs = [ pkg-config ];

  buildInputs = [ openssl openssl.dev ] ++ lib.optional pkgs.stdenv.isDarwin [
    libiconv
    darwin.apple_sdk.frameworks.Security
  ];
}
