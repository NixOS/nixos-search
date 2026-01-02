{
  lib ? import <nixpkgs/lib>,
  pkgs ? import <nixpkgs> { },
}:

let
  runTestCase =
    {
      name,
      flakeUri ? null,
      expectedOutput,
    }:
    let
      # Evaluate flake_info.nix with the test flake
      actualOutput =
        (import ../flake_info.nix {
          flake = flakeUri;
          input-flake = flakeUri;
        }).all;

      sortByKey = lib.sort (
        a: b:
        let
          keyA = a.attribute_name or a.name;
          keyB = b.attribute_name or b.name;
        in
        keyA < keyB
      );

      rmDerivationHash =
        entry:
        if entry.entry_type == "app" && builtins.hasAttr "bin" entry then
          entry
          // {
            # the bin field contains a derivation with a hash that changes on each eval
            # e.g "/nix/store/sqw9kyl8zrfnkklb3vp6gji9jw9qfgb5-hello-2.12.2/bin/hello"
            # replace to "hello-2.12.2/bin/hello" for stable comparison
            bin =
              let
                # Remove /nix/store/ and the hash (32 chars) from the path
                stripStoreHash =
                  s:
                  if lib.hasPrefix "/nix/store/" s then
                    lib.substring (lib.stringLength "/nix/store/" + 32 + 1) (
                      lib.stringLength s - (lib.stringLength "/nix/store/" + 32 + 1)
                    ) s
                  else
                    s;
              in
              stripStoreHash entry.bin;

          }
        else
          entry;

      sortedExpected = sortByKey (map rmDerivationHash expectedOutput);
      sortedActual = sortByKey (map rmDerivationHash actualOutput);

      passed = sortedExpected == sortedActual;

      # Build maps for comparison
      expectedMap = builtins.listToAttrs (
        map (e: {
          name = e.attribute_name or e.name;
          value = e;
        }) sortedExpected
      );
      actualMap = builtins.listToAttrs (
        map (e: {
          name = e.attribute_name or e.name;
          value = e;
        }) sortedActual
      );

      # Find differences
      expectedKeys = builtins.attrNames expectedMap;
      actualKeys = builtins.attrNames actualMap;

      missingKeys = lib.filter (k: !(actualMap ? ${k})) expectedKeys;
      extraKeys = lib.filter (k: !(expectedMap ? ${k})) actualKeys;
      commonKeys = lib.filter (k: expectedMap ? ${k} && actualMap ? ${k}) expectedKeys;
      mismatchedKeys = lib.filter (k: expectedMap.${k} != actualMap.${k}) commonKeys;
    in
    {
      inherit
        name
        passed
        sortedExpected
        sortedActual
        missingKeys
        extraKeys
        mismatchedKeys
        expectedMap
        actualMap
        ;
    };

  testCases =
    let
      readExpected = file: builtins.fromJSON (builtins.readFile file);
    in
    [
      {
        name = "basic-flake";
        flakeUri = "path:${toString ./basic-flake}";
        expectedOutput = readExpected ./expected-outputs/basic-flake.json;
      }
      {
        name = "hydra";
        flakeUri = "github:NixOS/hydra/241ab718002ca5740b7e3f659d0fbd483ab40523";
        expectedOutput = readExpected ./expected-outputs/hydra.json;
      }
      {
        name = "agenix";
        flakeUri = "github:ryantm/agenix/fcdea223397448d35d9b31f798479227e80183f6";
        expectedOutput = readExpected ./expected-outputs/agenix.json;
      }
      {
        name = "deploy-rs";
        flakeUri = "github:serokell/deploy-rs/9c870f63e28ec1e83305f7f6cb73c941e699f74f";
        expectedOutput = readExpected ./expected-outputs/deploy-rs.json;
      }
    ];

  results = map runTestCase testCases;

  allPassed = lib.all (r: r.passed) results;

  failedTests = lib.filter (r: !r.passed) results;

  successOutput = lib.concatMapStringsSep "\n" (
    result:
    let
      entries = result.sortedExpected;
      entryCount = lib.length entries;
      packageCount = lib.length (lib.filter (e: e.entry_type == "package") entries);
      optionCount = lib.length (lib.filter (e: e.entry_type == "option") entries);
    in
    ''
      echo "✓ ${result.name} (${toString entryCount} entries: ${toString packageCount} packages, ${toString optionCount} options)"
    ''
  ) results;

  failureOutput = lib.concatMapStringsSep "\n\n" (
    result:
    let
      expectedCount = lib.length result.sortedExpected;
      actualCount = lib.length result.sortedActual;
      missingCount = lib.length result.missingKeys;
      extraCount = lib.length result.extraKeys;
      mismatchedCount = lib.length result.mismatchedKeys;

      showSample = list: limit: lib.concatStringsSep ", " (lib.take limit list);
    in
    ''
      ❌ ${result.name} failed!

      Expected: ${toString expectedCount} entries
      Actual:   ${toString actualCount} entries

      ${lib.optionalString (missingCount > 0) ''
        Missing entries (${toString missingCount}):
        ${showSample result.missingKeys 10}${lib.optionalString (missingCount > 10) "..."}
      ''}
      ${lib.optionalString (extraCount > 0) ''
        Extra entries (${toString extraCount}):
        ${showSample result.extraKeys 10}${lib.optionalString (extraCount > 10) "..."}
      ''}
      ${
        if mismatchedCount > 0 then
          ''
            Mismatched entries (${toString mismatchedCount}):
            ${
              lib.concatMapStringsSep "\n" (
                k:
                let
                  exp = result.expectedMap.${k};
                  act = result.actualMap.${k};
                  expJson = builtins.toJSON exp;
                  actJson = builtins.toJSON act;
                in
                "  ${k}:\n    Expected: ${expJson}\n    Actual:   ${actJson}"
              ) (lib.take 3 result.mismatchedKeys)
            }${lib.optionalString (mismatchedCount > 3) "\n  ... and ${toString (mismatchedCount - 3)} more"}
          ''
        else
          ''
            Want: ${builtins.toJSON result.sortedExpected}
            Got:  ${builtins.toJSON result.sortedActual}
          ''
      }
    ''
  ) failedTests;

in
if allPassed then
  pkgs.runCommand "flake-info-tests-passed"
    {
      preferLocalBuild = true;
      allowSubstitutes = false;
    }
    ''
      echo "=============================="
      echo "flake_info.nix Tests"
      echo "=============================="
      echo ""
      ${successOutput}
      echo ""
      echo "=============================="
      echo "All ${toString (lib.length results)} test(s) passed!"
      echo "=============================="

      mkdir -p $out
      echo "success" > $out/result
    ''
else
  throw ''
    ==============================
    Test Failures
    ==============================

    ${failureOutput}

    ${toString (lib.length failedTests)} of ${toString (lib.length results)} test(s) failed.
  ''
