{ pkgs ? import <nixpkgs> { } }: with pkgs;
rustPlatform.buildRustPackage {
  name = "flake-info";
  src = ./.;
  cargoLock = {
    lockFile = ./Cargo.lock;
    outputHashes = {
      "elasticsearch-8.0.0-alpha.1" = "sha256-gjmk3Q3LTAvLhzQ+k1knSp1HBwtqNiubjXNnLy/cS5M=";
      "pandoc-0.8.6" = "sha256-NsHDzqWjQ17cznjOSpXOdUOhJjAO28Z6QZ6Mn6afVVs=";
    };
  };
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ pandoc openssl openssl.dev ] ++ lib.optional pkgs.stdenv.isDarwin [ libiconv darwin.apple_sdk.frameworks.Security ];
  checkFlags = [
    "--skip elastic::tests"
    "--skip nix_gc::tests"
    "--skip data::export::tests::test_option"
  ];
}
