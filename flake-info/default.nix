{ pkgs ? import <nixpkgs> { } }:

let nix = pkgs.nixUnstable.override {
    patches = [(
        pkgs.fetchpatch {
    name = "1230.patch";
    url = "https://patch-diff.githubusercontent.com/raw/NixOS/nix/pull/1230.patch";
    sha256 = "sha256-iL4m8j0ootuWDnKfrdme4vIkCHTTtbxQxnf6VLdIn6o=";
    })];
};


in
nix

# pkgs.rustPlatform.buildRustPackage rec {
#     name = "flake-info";
#     src = ./flake-info;
#     cargoSha256 = "sha256-JPMthz+z9qNG6CK8F+P/iG77VCd0X7/dyS3YpKeGskc=";
#     buildInputs = [ ] ++ optional pkgs.lib.isDarwin [pkgs.libiconv pkgs.darwin.apple_sdk.frameworks.Security];
#     checkFlags = [
#         "--skip elastic::tests"
#         "--skip nix_gc::tests"
#     ];
# }
