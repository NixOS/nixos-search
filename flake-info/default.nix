{ pkgs, flake-schemas }:
let
  # GitLab.com sends a Cloudflare challenge (HTTP 403) for the list endpoint
  # that the `gitlab` fetcher uses. Remove when the patch is in `pkgs.nix`.
  nix = pkgs.nix.appendPatches [
    (pkgs.fetchpatch {
      name = "libfetchers-gitlab-single-commit-endpoint.patch";
      url = "https://github.com/NixOS/nix/commit/dbd8a75eecb92342f510c3eafc4504e4e590dc2b.patch";
      includes = [ "src/libfetchers/github.cc" ];
      hash = "sha256-9+qqu70fJO284aGFfGRBB30/IJcihg3CeR2o7gG40HA=";
    })
  ];
in
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
    with pkgs;
    [
      openssl
      openssl.dev
      makeWrapper
    ]
    ++ lib.optional pkgs.stdenv.hostPlatform.isDarwin [
      libiconv
      apple-sdk
    ];

  checkInputs = with pkgs; [ pandoc ];

  ROOTDIR = builtins.placeholder "out";
  LINK_MANPAGES_PANDOC_FILTER = import src/data/link-manpages.nix { inherit pkgs; };
  # Baked in at build time so `nix eval -f assets/commands/flake_info.nix` can
  # resolve the `flake-schemas` registry override to a locked ref.
  FLAKE_SCHEMAS_REF = "github:DeterminateSystems/flake-schemas/${flake-schemas.rev}";

  checkFlags = [
    "--skip elastic::tests"
  ];

  postInstall = ''
    cp -rt "$out" assets

    wrapProgram $out/bin/flake-info \
      --prefix PATH : ${
        pkgs.lib.makeBinPath [
          nix
          pkgs.pandoc
          pkgs.nix-eval-jobs
        ]
      }
  '';
}
