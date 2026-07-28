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
      packages =
        forAllSystems (
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

            # Not a derivation, so it has no `name` -- must be dropped rather
            # than emitted as a name-less package entry.
            not-a-derivation = {
              some = "attrset";
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
        )
        // {
          # A system whose entire package set throws -- that system must be
          # skipped rather than aborting evaluation of the whole flake.
          riscv64-linux = throw "this system is not supported";
        };

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

          # Throws on every system: the attribute is dropped rather than
          # aborting evaluation of the whole flake.
          throwing-app = {
            type = "app";
            program = throw "this app cannot be evaluated";
          };

          # Throws only on darwin: the attribute survives, listing just the
          # platforms it evaluated on.
          partly-throwing-app = {
            type = "app";
            program =
              if pkgs.stdenv.isDarwin then
                throw "this app is unsupported on darwin"
              else
                pkgs.hello.outPath + "/bin/hello";
          };
        }
      );
    };
}
