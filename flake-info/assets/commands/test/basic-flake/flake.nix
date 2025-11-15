{
  description = "Test flake for flake_info.nix";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          # Package available on all systems
          hello = pkgs.writeShellScriptBin "hello" ''
            echo "Hello from all systems"
          '';

          # Package available on all systems with metadata
          test-package = pkgs.stdenv.mkDerivation {
            pname = "test-package";
            version = "1.2.3";
            src = pkgs.writeText "test.txt" "test content";
            dontUnpack = true;
            installPhase = ''
              mkdir -p $out
              cp $src $out/test.txt
            '';
            meta = with pkgs.lib; {
              description = "A test package";
              longDescription = "This is a longer description for testing";
              license = licenses.mit;
            };
          };
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.isDarwin {
          # Darwin-only package
          darwin-specific = pkgs.writeShellScriptBin "darwin-test" ''
            echo "Darwin only"
          '';
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          # Linux-only package
          linux-specific = pkgs.writeShellScriptBin "linux-test" ''
            echo "Linux only"
          '';
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          app-hello = {
            type = "app";
            program = pkgs.hello.outPath + "/bin/hello";
          };
        }
      );
    };
}
