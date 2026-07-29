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

            # Package with dynamic & custom metadata
            custom-meta-package = pkgs.stdenv.mkDerivation {
              pname = "custom-meta-package";
              version = "2.0.0";
              src = pkgs.writeText "test.txt" "content";
              dontUnpack = true;
              meta = {
                description = "Package with custom metadata";
                customAttr = "new_future_field";
                mainProgram = "custom-binary";
              };
            };

            # Package with one broken meta field that throws
            field-throwing-package = pkgs.stdenv.mkDerivation {
              pname = "field-throwing-package";
              version = "1.0.0";
              src = pkgs.writeText "test.txt" "content";
              dontUnpack = true;
              meta = {
                description = "Package with one broken meta key";
                brokenKey = throw "this meta key throws";
              };
            };

            # Package explicitly marked broken
            broken-package = pkgs.stdenv.mkDerivation {
              pname = "broken-package";
              version = "1.0.0";
              src = pkgs.writeText "test.txt" "content";
              dontUnpack = true;
              meta = {
                description = "Broken package";
                broken = true;
              };
            };

            # Package whose derivation name throws an evaluation error
            throwing-package = pkgs.stdenv.mkDerivation {
              name = throw "derivation name throws";
              src = pkgs.writeText "test.txt" "content";
              dontUnpack = true;
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

      legacyPackages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          nestedSet = pkgs.lib.recurseIntoAttrs {
            nested-package = pkgs.writeShellScriptBin "nested-package" ''
              echo "Nested package"
            '';
          };
        }
      );
    };
}
