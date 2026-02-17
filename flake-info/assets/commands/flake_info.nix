{
  flake ? null,
  input-flake ? "input-flake",
}:
let
  resolved = builtins.getFlake input-flake;

  nixpkgs = (import <nixpkgs> { });
  lib = nixpkgs.lib;

  # filter = lib.filterAttrs (key: _ : key == "apps" || key == "packages");

  # Reference system to use for extracting full package metadata
  # For other systems, we only check attribute names to avoid redundant evaluation
  referenceSystem = "x86_64-linux";

  withSystem = fn: lib.mapAttrs (system: drvs: (fn system drvs));

  readPackages =
    system: drvs:
    let
      # Safely evaluate metadata fields that might be expensive or broken
      # Returns { success = bool; value = any; }
      safeEval = attr: builtins.tryEval attr;

      # Full evaluation - used for reference system
      processPackageFull =
        attribute_name: drv:
        let
          # Try to get basic derivation info without forcing expensive evaluation
          typeCheck = builtins.tryEval (builtins.isAttrs drv && drv ? type);

          # Only proceed if it looks like it could be a derivation
          derivResult =
            if typeCheck.success && typeCheck.value then
              safeEval (lib.isDerivation drv)
            else
              {
                success = false;
                value = false;
              };

          # Early exit if not a valid derivation
          nameResult =
            if derivResult.success && derivResult.value then
              safeEval drv.name
            else
              {
                success = false;
                value = null;
              };

          # Check if broken - only if we got this far
          brokenResult =
            if nameResult.success then
              safeEval (drv.meta.broken or false)
            else
              {
                success = true;
                value = false;
              };

          isBroken = brokenResult.success && brokenResult.value;
        in
        # Only build package info if: it's a derivation, has a name, and is not broken
        if nameResult.success && !isBroken then
          let
            versionResult = safeEval (drv.version or "");
            outputsResult = safeEval drv.outputs;
            outputNameResult = safeEval drv.outputName;
            descResult = safeEval (drv.meta.description or null);
            longDescResult = safeEval (drv.meta.longDescription or null);
            licenseResult = safeEval (drv.meta.license or null);
          in
          {
            entry_type = "package";
            attribute_name = attribute_name;
            system = system;
            name = nameResult.value;
            version = if versionResult.success then versionResult.value else "";
            outputs = if outputsResult.success then outputsResult.value else [ "out" ];
            default_output = if outputNameResult.success then outputNameResult.value else "out";
          }
          // lib.optionalAttrs (descResult.success && descResult.value != null) {
            description = descResult.value;
          }
          // lib.optionalAttrs (longDescResult.success && longDescResult.value != null) {
            longDescription = longDescResult.value;
          }
          // lib.optionalAttrs (licenseResult.success && licenseResult.value != null) {
            license = licenseResult.value;
          }
        else
          null;

      # Lightweight evaluation - only attribute name and system, no package evaluation
      processPackageLight = attribute_name: drv: {
        entry_type = "package";
        attribute_name = attribute_name;
        system = system;
        # Don't access any attributes of drv to avoid forcing evaluation
      };

      # Use full processing for reference system, lightweight for others
      results =
        if system == referenceSystem then
          lib.mapAttrsToList processPackageFull drvs
        else
          lib.mapAttrsToList processPackageLight drvs;
    in
    # Filter out null entries (only relevant for full processing)
    if system == referenceSystem then builtins.filter (x: x != null) results else results;
  readApps =
    system: apps:
    lib.mapAttrsToList (
      attribute_name: app:
      (
        {
          entry_type = "app";
          attribute_name = attribute_name;
          system = system;
        }
        // lib.optionalAttrs (app ? outPath) { bin = app.outPath; }
        // lib.optionalAttrs (app ? program) { bin = app.program; }
        // lib.optionalAttrs (app ? type) { type = app.type; }
      )
    ) apps;

  readNixOSOptions =
    let
      declarations =
        module:
        (lib.evalModules {
          modules = (if lib.isList module then module else [ module ]) ++ [
            (
              { ... }:
              {
                _module.check = false;
              }
            )
          ];
          specialArgs = {
            # !!! NixOS-specific. Unfortunately, NixOS modules can rely on the `modulesPath`
            # argument to import modules from the nixos tree. However, most of the time
            # this is done to import *profiles* which do not declare any options, so we
            # can allow it.
            modulesPath = "${nixpkgs.path}/nixos/modules";

            # Provide commonly-used arguments so module evaluation that expects them
            # (e.g. `pkgs` or `config`) does not fail during CI evaluation.
            pkgs = nixpkgs;
          };
        }).options;

      cleanUpOption =
        extraAttrs: opt:
        let
          applyOnAttr = n: f: lib.optionalAttrs (builtins.hasAttr n opt) { ${n} = f opt.${n}; };
          mkDeclaration =
            decl:
            let
              discard = lib.concatStringsSep "/" (lib.take 4 (lib.splitString "/" decl)) + "/";
              path = if lib.hasPrefix builtins.storeDir decl then lib.removePrefix discard decl else decl;
            in
            path;

          # Replace functions by the string <function>
          substFunction =
            x:
            if builtins.isAttrs x then
              lib.mapAttrs (_: substFunction) x
            else if builtins.isList x then
              map substFunction x
            else if lib.isFunction x then
              "function"
            else
              x;
        in
        opt
        // {
          entry_type = "option";
        }
        // applyOnAttr "default" substFunction
        // applyOnAttr "example" substFunction # (_: { __type = "function"; })
        // applyOnAttr "type" substFunction
        // applyOnAttr "declarations" (map mkDeclaration)
        // extraAttrs;
    in
    {
      module,
      modulePath ? null,
    }:
    let
      opts = lib.optionAttrSetToDocList (declarations module);
      extraAttrs = lib.optionalAttrs (modulePath != null) {
        flake = modulePath;
      };
    in
    map (cleanUpOption extraAttrs) (
      lib.filter (x: x.visible && !x.internal && lib.head x.loc != "_module") opts
    );

  readFlakeOptions =
    let
      nixosModulesOpts = builtins.concatLists (
        lib.mapAttrsToList (
          moduleName: module:
          readNixOSOptions {
            inherit module;
            modulePath = [
              flake
              moduleName
            ];
          }
        ) (resolved.nixosModules or { })
      );

      nixosModuleOpts = lib.optionals (resolved ? nixosModule) (readNixOSOptions {
        module = resolved.nixosModule;
        modulePath = [ flake ];
      });
    in
    # We assume that `nixosModules` includes `nixosModule` when there
    # are multiple modules
    if nixosModulesOpts != [ ] then nixosModulesOpts else nixosModuleOpts;

  read = reader: set: lib.flatten (lib.attrValues (withSystem reader set));

  # Get all package sets by system for potential fallback evaluation
  allPackageSets = {
    legacyPackages = resolved.legacyPackages or { };
    packages = resolved.packages or { };
  };

  legacyPackages' = read readPackages (resolved.legacyPackages or { });
  packages' = read readPackages (resolved.packages or { });

  apps' = read readApps (resolved.apps or { });

  # Helper to fully evaluate a package from a specific system when needed
  evaluatePackageFromSystem =
    pkgSet: system: attribute_name:
    let
      drvs = pkgSet.${system} or { };
      drv = drvs.${attribute_name} or null;
      safeEval = attr: builtins.tryEval attr;

      typeCheck = builtins.tryEval (builtins.isAttrs drv && drv ? type);
      derivResult =
        if typeCheck.success && typeCheck.value then
          safeEval (lib.isDerivation drv)
        else
          {
            success = false;
            value = false;
          };
      nameResult =
        if derivResult.success && derivResult.value then
          safeEval drv.name
        else
          {
            success = false;
            value = null;
          };
      brokenResult =
        if nameResult.success then
          safeEval (drv.meta.broken or false)
        else
          {
            success = true;
            value = false;
          };
      isBroken = brokenResult.success && brokenResult.value;
    in
    if nameResult.success && !isBroken then
      let
        versionResult = safeEval (drv.version or "");
        outputsResult = safeEval drv.outputs;
        outputNameResult = safeEval drv.outputName;
        descResult = safeEval (drv.meta.description or null);
        longDescResult = safeEval (drv.meta.longDescription or null);
        licenseResult = safeEval (drv.meta.license or null);
      in
      {
        name = nameResult.value;
        version = if versionResult.success then versionResult.value else "";
        outputs = if outputsResult.success then outputsResult.value else [ "out" ];
        default_output = if outputNameResult.success then outputNameResult.value else "out";
      }
      // lib.optionalAttrs (descResult.success && descResult.value != null) {
        description = descResult.value;
      }
      // lib.optionalAttrs (longDescResult.success && longDescResult.value != null) {
        longDescription = longDescResult.value;
      }
      // lib.optionalAttrs (licenseResult.success && licenseResult.value != null) {
        license = licenseResult.value;
      }
    else
      null;

  collectSystems =
    pkgSet: list:
    lib.lists.foldr (
      drv@{ attribute_name, system, ... }:
      set:
      let
        # Check if this is a lightweight package entry (only has attribute_name, system, entry_type)
        # Apps are not lightweight - they have bin/type fields
        isLightweightPackage = !(drv ? name) && drv.entry_type == "package";

        # For apps, check if they have metadata (bin/type fields)
        isApp = drv.entry_type == "app";
        appHasMetadata = isApp && (drv ? bin || drv ? type);

        # Get existing entry or create new base
        present =
          set."${attribute_name}" or (
            if isLightweightPackage then
              {
                platforms = [ ];
                entry_type = "package";
                inherit attribute_name;
              }
            else
              ({ platforms = [ ]; } // drv)
          );

        # Check if present entry has metadata
        presentHasMetadata =
          present ? name || (present.entry_type == "app" && (present ? bin || present ? type));

        # Merge entries
        drv' =
          if isLightweightPackage then
            if presentHasMetadata then
              # Present has metadata, just add platform
              present
              // {
                platforms = present.platforms ++ [ system ];
              }
            else
              # Present lacks metadata, this must be a platform-specific package
              # Evaluate it from this system
              let
                metadata = evaluatePackageFromSystem pkgSet system attribute_name;
              in
              if metadata != null then
                present
                // metadata
                // {
                  platforms = present.platforms ++ [ system ];
                }
              else
                # Evaluation failed, just add platform without metadata
                present
                // {
                  platforms = present.platforms ++ [ system ];
                }
          else
            # Current entry has full metadata (package with name, or app with bin/type)
            present
            // drv
            // {
              platforms = present.platforms ++ [ system ];
            };

        drv'' = removeAttrs drv' [ "system" ];
      in
      set
      // {
        ${attribute_name} = drv'';
      }
    ) { } list;

in

rec {
  legacyPackages = lib.attrValues (collectSystems allPackageSets.legacyPackages legacyPackages');
  packages = lib.attrValues (collectSystems allPackageSets.packages packages');
  apps = lib.attrValues (collectSystems { } apps'); # apps don't need fallback evaluation
  options = readFlakeOptions;
  all = packages ++ apps ++ options;

  # nixpkgs-specific, doesn't use the flake argument
  nixos-options = readNixOSOptions {
    module = import <nixpkgs/nixos/modules/module-list.nix> ++ [
      <nixpkgs/nixos/modules/virtualisation/qemu-vm.nix>
      { nixpkgs.hostPlatform = "x86_64-linux"; }
    ];
  };
}
