{ pkgs ? import <nixpkgs> {}
}:
pkgs.rustPlatform.buildRustPackage rec {
  name = "flake-info";
  src = ./.;
  cargoLock = {
    lockFile = ./Cargo.lock;
    outputHashes = {
      "elasticsearch-8.0.0-alpha.1" = "sha256-gjmk3Q3LTAvLhzQ+k1knSp1HBwtqNiubjXNnLy/cS5M=";
    };
  };
  nativeBuildInputs = with pkgs; [ pkg-config ];
  buildInputs =
    with pkgs; [
      openssl
      openssl.dev
      makeWrapper
    ] ++ lib.optional pkgs.stdenv.isDarwin [
      libiconv
      darwin.apple_sdk.frameworks.Security
    ];

  checkInputs = with pkgs; [ pandoc ];

  ROOTDIR = builtins.placeholder "out";
  NIXPKGS_PANDOC_FILTERS_PATH = "${pkgs.path + "/doc/build-aux/pandoc-filters"}";

  checkFlags = [
    "--skip elastic::tests"
  ];

  postInstall = ''
    cp -rt "$out" assets

    wrapProgram $out/bin/flake-info \
      --prefix PATH : ${pkgs.pandoc}/bin
  '';
}
