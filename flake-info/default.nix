{ pkgs ? import <nixpkgs> { } }: with pkgs;
rustPlatform.buildRustPackage {
  name = "flake-info";
  src = ./.;
  cargoLock = {
    lockFile = ./Cargo.lock;
    outputHashes = {
      "elasticsearch-8.0.0-alpha.1" = "0x8iw4m16vy6i28mj30aqdwfw4a3hd174l8l9yigddn3cr53cagx";
    };
  };
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ pandoc openssl openssl.dev ] ++ lib.optional pkgs.stdenv.isDarwin [ libiconv darwin.apple_sdk.frameworks.Security ];
  postInstall = ''
    makeWrapper $out/bin/flake-info \
      --set NIXPKGS_PANDOC_FILTERS_PATH "${pkgs.path + "/doc/build-aux/pandoc-filters"}"
  '';
  checkFlags = [
    "--skip elastic::tests"
    "--skip nix_gc::tests"
  ];
}
