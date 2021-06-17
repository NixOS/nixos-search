{ pkgs ? import <nixpkgs> { } }: with pkgs;




rustPlatform.buildRustPackage rec {
    name = "flake-info";
    src = ./.;
    cargoSha256 = "sha256-JPMthz+z9qNG6CK8F+P/iG77VCd0X7/dyS3YpKeGskc=";
    buildInputs = [ ] ++ lib.optional pkgs.stdenv.isDarwin [libiconv darwin.apple_sdk.frameworks.Security];
    checkFlags = [
        "--skip elastic::tests"
        "--skip nix_gc::tests"
    ];
}
