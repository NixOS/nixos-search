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

  # Strip store-path prefix from a declaration path
  mkDeclaration =
    decl:
    let
      discard = lib.concatStringsSep "/" (lib.take 4 (lib.splitString "/" decl)) + "/";
      path = if lib.hasPrefix builtins.storeDir decl then lib.removePrefix discard decl else decl;
    in
    path;

  # Clean up a raw option attrset for indexing
  cleanUpOption =
    extraAttrs: opt:
    let
      applyOnAttr = n: f: lib.optionalAttrs (builtins.hasAttr n opt) { ${n} = f opt.${n}; };
    in
    opt
    // {
      entry_type = extraAttrs.entry_type or "option";
    }
    // applyOnAttr "default" substFunction
    // applyOnAttr "example" substFunction
    // applyOnAttr "type" substFunction
    // applyOnAttr "declarations" (map mkDeclaration)
    // extraAttrs;

  # Filter for user-visible, non-internal options
  filterOptions = opts: lib.filter (x: x.visible && !x.internal && lib.head x.loc != "_module") opts;

  readNixOSOptions =
    {
      module,
      modulePath ? null,
    }:
    let
      declarations =
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

      opts = lib.optionAttrSetToDocList declarations;
      extraAttrs = lib.optionalAttrs (modulePath != null) {
        flake = modulePath;
      };
    in
    map (cleanUpOption extraAttrs) (filterOptions opts);

  # Parses the angle-bracket prefix from modular service option names to extract
  # service_package and service_module, strips the prefix, and tags as entry_type = "service".
  parseServiceOption =
    opt:
    let
      # Match: <imports = [ pkgs.PKG.services.MODULE ]>.OPTNAME
      # Group 1: package attrname, group 2: module name, group 3: remaining option path
      m = builtins.match ".*imports.*pkgs\\.([^.]+)\\.services\\.([^ ]+).*>\\.(.*)" opt.name;
    in
    if m != null then
      opt
      // {
        entry_type = "service";
        name = builtins.elemAt m 2;
        service_package = builtins.elemAt m 0;
        service_module = builtins.elemAt m 1;
      }
    else
      # Fallback: keep as-is but still tag as service
      opt // { entry_type = "service"; };

  # Deduplicate service options that share the same underlying module. When
  # several packages re-export the same service module (e.g. php, php82..php85
  # all point to the same pkgs/development/interpreters/php/service.nix), we
  # end up with identical option entries differing only by service_package.
  # Group by (declarations, parsed name) and keep a single entry per group,
  # with a canonical service_package and the full list in service_packages.
  deduplicateServices =
    opts:
    let
      keyOf =
        opt:
        builtins.toJSON [
          (opt.declarations or [ ])
          (opt.name or "")
          (opt.service_module or "")
        ];
      addToGroup =
        acc: opt:
        let
          k = keyOf opt;
        in
        acc // { ${k} = (acc.${k} or [ ]) ++ [ opt ]; };
      grouped = lib.foldl' addToGroup { } opts;
      mergeGroup =
        entries:
        let
          # Sort packages alphabetically; the shortest/unversioned name (e.g.
          # "php") naturally sorts before versioned variants ("php82").
          packages = lib.sort (a: b: a < b) (lib.unique (map (e: e.service_package or "") entries));
        in
        (builtins.head entries)
        // {
          service_package = builtins.head packages;
          service_packages = packages;
        };
    in
    lib.mapAttrsToList (_: mergeGroup) grouped;

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

      raw =
        # We assume that `nixosModules` includes `nixosModule` when there
        # are multiple modules
        if nixosModulesOpts != [ ] then nixosModulesOpts else nixosModuleOpts;

      # When a flake re-exports the same module under multiple names
      # (e.g. `default` and `home-manager`), deduplicate by option name,
      # keeping the first occurrence.
      dedup =
        opts:
        let
          addOnce = acc: opt: if acc ? ${opt.name} then acc else acc // { ${opt.name} = opt; };
        in
        lib.attrValues (lib.foldl' addOnce { } opts);
    in
    dedup raw;

  # Extract options from home-manager's module system.
  # Only produces output when `resolved` points to a home-manager flake
  # (detected by the presence of `modules/modules.nix`).
  readHomeManagerOptions =
    let
      # Home-manager modules use `lib.hm.*` helpers; extend nixpkgs' lib with
      # HM's custom library so module evaluation does not fail.
      hmLib = import "${resolved}/modules/lib/stdlib-extended.nix" lib;

      hmModulesPath = "${resolved}/modules/modules.nix";
      hmModuleList =
        let
          fn = import hmModulesPath;
        in
        if builtins.isFunction fn then
          fn {
            lib = hmLib;
            pkgs = nixpkgs;
          }
        else
          fn;

      declarations =
        (hmLib.evalModules {
          modules = hmModuleList ++ [
            (
              { lib, ... }:
              {
                _module.check = lib.mkForce false;
              }
            )
          ];
          specialArgs = {
            pkgs = nixpkgs;
          };
        }).options;

      opts = hmLib.optionAttrSetToDocList declarations;
    in
    map (cleanUpOption { entry_type = "home-manager-option"; }) (filterOptions opts);

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

  # nixpkgs-specific, doesn't use the flake argument
  nixpkgsBaseModules = import <nixpkgs/nixos/modules/module-list.nix> ++ [
    <nixpkgs/nixos/modules/virtualisation/qemu-vm.nix>
    { nixpkgs.hostPlatform = "x86_64-linux"; }
  ];

  # Use nixpkgs' hand-maintained modular services list rather than walking all
  # `pkgs` attributes (which would force shallow evaluation of every package
  # and is too expensive -- see NixOS/nixpkgs#509117).
  serviceDocModules =
    (import <nixpkgs/nixos/modules/misc/documentation/modular-services.nix> {
      inherit lib;
      pkgs = nixpkgs;
    }).documentation.nixos.extraModules;

  # Evaluate base + service documentation modules together (service modules
  # depend on base option types). Then partition: options whose name starts
  # with "<" come from modular services.
  nixpkgsAllOpts = readNixOSOptions { module = nixpkgsBaseModules ++ serviceDocModules; };
  isServiceOption = opt: lib.hasPrefix "<" opt.name;

in

rec {
  legacyPackages = lib.attrValues (collectSystems allPackageSets.legacyPackages legacyPackages');
  packages = lib.attrValues (collectSystems allPackageSets.packages packages');
  apps = lib.attrValues (collectSystems { } apps'); # apps don't need fallback evaluation
  options = readFlakeOptions;
  home-manager-options =
    let
      hasHmModules = builtins.tryEval (builtins.pathExists "${resolved}/modules/modules.nix");
    in
    if hasHmModules.success && hasHmModules.value then readHomeManagerOptions else [ ];
  all = packages ++ apps ++ options ++ home-manager-options;

  nixos-options = builtins.filter (opt: !(isServiceOption opt)) nixpkgsAllOpts;

  nixos-services =
    let
      parsed = map parseServiceOption (builtins.filter isServiceOption nixpkgsAllOpts);
      # Filter out top-level submodule container entries (no service_package means regex didn't match)
      real = builtins.filter (opt: opt ? service_package) parsed;
    in
    deduplicateServices real;

  # Map from package attribute name to the list of modular service module
  # names it exposes. Derived from the parsed service options above so it
  # stays in sync with nixpkgs' hand-maintained list.
  nixos-package-services =
    let
      parsed = map parseServiceOption (builtins.filter isServiceOption nixpkgsAllOpts);
      real = builtins.filter (opt: opt ? service_package) parsed;
    in
    lib.foldl' (
      acc: opt:
      acc
      // {
        ${opt.service_package} = lib.unique ((acc.${opt.service_package} or [ ]) ++ [ opt.service_module ]);
      }
    ) { } real;
}
