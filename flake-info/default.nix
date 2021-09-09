{ pkgs ? import <nixpkgs> { } }: with pkgs;
rustPlatform.buildRustPackage {
  name = "flake-info";
  src = ./.;
  cargoLock = {
    lockFile = ./Cargo.lock;
    outputHashes = {
      "elasticsearch-8.0.0-alpha.1" = "sha256-gjmk3Q3LTAvLhzQ+k1knSp1HBwtqNiubjXNnLy/cS5M=";
    };
  };
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ pandoc openssl openssl.dev ] ++ lib.optional pkgs.stdenv.isDarwin [ libiconv darwin.apple_sdk.frameworks.Security ];
  checkInputs = [ pandoc ];
  checkFlags = [
    "--skip elastic::tests"
    "--skip nix_gc::tests"
  ];
}
