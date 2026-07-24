{
  targetFlake,
  nixpkgsFlake,
  flake-schemas,
  targetFlakeUri ? if builtins.isString targetFlake then targetFlake else null,
}:
let
  resolved = if builtins.isAttrs targetFlake then targetFlake else builtins.getFlake targetFlake;

  inherit (nixpkgsFlake) lib;
  nixpkgs = nixpkgsFlake.legacyPackages.${referenceSystem};

  # Reference system to use for extracting full package metadata
  # For other systems, we only check attribute names to avoid redundant evaluation
  referenceSystem = "x86_64-linux";

  withSystem = fn: lib.mapAttrs (system: drvs: (fn system drvs));

  safeEval = attr: lib.tryEval attr;

  evalDrvMetadata =
    drv:
    let
      derivResult = safeEval (lib.isDerivation drv);
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

  getSchemaInventory =
    key:
    if resolved ? ${key} && schemas ? ${key} then
      let
        inv = safeEval (schemas.${key}.inventory resolved.${key});
      in
      if inv.success && inv.value ? children then inv.value.children else { }
    else
      { };

  # Extract package and app entries using schema inventory functions
  readSchemaItems =
    schemaKey: entryType:
    builtins.concatLists (
      lib.mapAttrsToList (
        system: sysNode:
        lib.filter (x: x != null) (
          lib.mapAttrsToList (
            attribute_name: itemNode:
            let
              rawVal = resolved.${schemaKey}.${system}.${attribute_name} or null;
              val = lib.findFirst (x: x != null) rawVal [
                (itemNode.value or null)
                (itemNode.derivation or null)
                (itemNode.app or null)
              ];
              binPath =
                itemNode.program or (if lib.isAttrs val then (val.program or val.outPath or null) else null);
            in
            if entryType == "app" then
              {
                entry_type = "app";
                inherit attribute_name system;
              }
              // lib.optionalAttrs (binPath != null) { bin = binPath; }
              // lib.optionalAttrs (itemNode ? type || (lib.isAttrs val && val ? type)) {
                type = itemNode.type or (if lib.isAttrs val then val.type or "app" else "app");
              }
            else if system == referenceSystem then
              let
                meta = evalDrvMetadata val;
              in
              if meta != null then
                {
                  entry_type = "package";
                  inherit attribute_name system;
                }
                // meta
              else
                null
            else
              {
                entry_type = "package";
                inherit attribute_name system;
              }
          ) (sysNode.children or { })
        )
      ) (getSchemaInventory schemaKey)
    );

  legacyPackages' = readSchemaItems "legacyPackages" "package";
  packages' = readSchemaItems "packages" "package";
  apps' = readSchemaItems "apps" "app";

  # Replace functions by the string <function>
  substFunction =
    x:
    if lib.isAttrs x then
      lib.mapAttrs (_: substFunction) x
    else if lib.isList x then
      map substFunction x
    else if lib.isFunction x then
      "function"
    else
      x;

  # Strip store-path prefix from a declaration path
  mkDeclaration =
    decl:
    if lib.hasPrefix builtins.storeDir decl then
      lib.concatStringsSep "/" (lib.drop 4 (lib.splitString "/" decl))
    else
      decl;

  # Clean up a raw option attrset for indexing
  cleanUpOption =
    extraAttrs: opt:
    let
      applyOnAttr = n: f: lib.optionalAttrs (opt ? ${n}) { ${n} = f opt.${n}; };
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

  evalOptionsWith =
    {
      evalModules ? lib.evalModules,
      modules,
      specialArgs ? { },
      class ? null,
      extraAttrs ? { },
    }:
    let
      declarations =
        (evalModules (
          {
            modules = modules ++ [
              (
                { lib, ... }:
                {
                  _module.check = lib.mkForce false;
                }
              )
            ];
            specialArgs = {
              pkgs = nixpkgs;
            }
            // specialArgs;
          }
          // lib.optionalAttrs (class != null) { inherit class; }
        )).options;

      opts = lib.optionAttrSetToDocList declarations;
    in
    map (cleanUpOption extraAttrs) (filterOptions opts);

  readNixOSOptions =
    {
      module,
      modulePath ? null,
    }:
    evalOptionsWith {
      modules = if lib.isList module then module else [ module ];
      specialArgs = {
        # !!! NixOS-specific. Unfortunately, NixOS modules can rely on the `modulesPath`
        # argument to import modules from the nixos tree. However, most of the time
        # this is done to import *profiles* which do not declare any options, so we
        # can allow it.
        modulesPath = "${nixpkgsFlake}/nixos/modules";
      };
      extraAttrs = lib.optionalAttrs (modulePath != null) {
        flake = modulePath;
      };
    };

  # Parses the angle-bracket prefix from modular service option names to extract
  # service_package and service_module, strips the prefix, and tags as entry_type = "service".
  parseServiceOption =
    opt:
    let
      # Match: <imports = [ pkgs.PKG.services.MODULE ]>.OPTNAME
      # Group 1: package attrname, group 2: module name, group 3: remaining option path
      m = lib.match ".*imports.*pkgs\\.([^.]+)\\.services\\.([^ ]+).*>\\.(.*)" opt.name;
    in
    if m != null then
      opt
      // {
        entry_type = "service";
        name = lib.elemAt m 2;
        service_package = lib.elemAt m 0;
        service_module = lib.elemAt m 1;
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
    opts
    |> lib.groupBy (
      opt:
      lib.toJSON [
        (opt.declarations or [ ])
        (opt.name or "")
        (opt.service_module or "")
      ]
    )
    |> lib.mapAttrsToList (
      _: entries:
      let
        packages = lib.naturalSort (lib.unique (map (e: e.service_package or "") entries));
      in
      (lib.head entries)
      // {
        service_package = lib.head packages;
        service_packages = packages;
      }
    );

  # Base schemas from official flake-schemas input extended with custom schemas
  schemas = flake-schemas.exportedSchemas // (resolved.schemas or { });

  readFlakeOptions =
    let
      invModules = lib.mapAttrs (
        name: n:
        if lib.isFunction (n.value or n.module or null) || lib.isAttrs (n.value or n.module or null) then
          n.value or n.module
        else
          resolved.nixosModules.${name} or n
      ) (getSchemaInventory "nixosModules");
      moduleSet = if invModules != { } then invModules else resolved.nixosModules or { };

      raw = lib.concatLists (
        lib.mapAttrsToList (
          moduleName: module:
          readNixOSOptions {
            inherit module;
            modulePath = [
              (if targetFlakeUri != null then targetFlakeUri else targetFlake)
              moduleName
            ];
          }
        ) moduleSet
      );

      # When a flake re-exports the same module under multiple names
      # (e.g. `default` and `home-manager`), deduplicate by option name,
      # keeping the first occurrence.
      dedup = opts: lib.attrValues (lib.mapAttrs (_: lib.head) (lib.groupBy (opt: opt.name) opts));
    in
    dedup raw;

  # Extract options from home-manager's module system.
  # Evaluated separately during the nixpkgs channel import (via
  # `--override-flake input-flake github:nix-community/home-manager`) so that
  # home-manager options land in the channel index alongside NixOS options.
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
        if lib.isFunction fn then
          fn {
            lib = hmLib;
            pkgs = nixpkgs;
          }
        else
          fn;
    in
    evalOptionsWith {
      evalModules = hmLib.evalModules;
      modules = hmModuleList;
      extraAttrs = {
        entry_type = "home-manager-option";
      };
    };

  # Extract options from nix-darwin's module system.
  # Evaluated separately during the nixpkgs channel import (via
  # `--override-flake input-flake github:nix-darwin/nix-darwin`) so that
  # nix-darwin options land in the channel index alongside NixOS options.
  readDarwinOptions =
    let
      darwinModulesPath = "${resolved}/modules/module-list.nix";
      darwinModuleList = import darwinModulesPath;
    in
    evalOptionsWith {
      modules = darwinModuleList;
      extraAttrs = {
        entry_type = "darwin-option";
      };
    };

  # Helper to fully evaluate a package from a specific system when needed
  evaluatePackageFromSystem =
    outputKey: system: attribute_name:
    evalDrvMetadata (resolved.${outputKey}.${system}.${attribute_name} or null);

  collectSystems =
    outputKey: list:
    let
      grouped = lib.groupBy (x: x.attribute_name) list;
      mergeEntry =
        attribute_name: entries:
        let
          firstWithMeta =
            let
              found = lib.findFirst (e: e ? name || e ? bin) null entries;
            in
            if found != null then
              found
            else
              let
                firstEntry = lib.head entries;
                meta = evaluatePackageFromSystem outputKey firstEntry.system attribute_name;
              in
              if meta != null then firstEntry // meta else firstEntry;

          rawPlatforms = lib.unique (map (e: e.system) entries);
          targetOrder = [
            "x86_64-linux"
            "x86_64-darwin"
            "aarch64-linux"
            "aarch64-darwin"
          ];
          platforms =
            (lib.filter (x: lib.elem x rawPlatforms) targetOrder)
            ++ (lib.filter (x: !(lib.elem x targetOrder)) rawPlatforms);
        in
        removeAttrs (firstWithMeta // { inherit platforms; }) [ "system" ];
    in
    lib.mapAttrs mergeEntry grouped;

  # nixpkgs-specific, doesn't use the flake argument
  nixpkgsBaseModules = import "${nixpkgsFlake}/nixos/modules/module-list.nix" ++ [
    "${nixpkgsFlake}/nixos/modules/virtualisation/qemu-vm.nix"
    { nixpkgs.hostPlatform = "x86_64-linux"; }
  ];

  # Use nixpkgs' hand-maintained modular services list rather than walking all
  # `pkgs` attributes (which would force shallow evaluation of every package
  # and is too expensive -- see NixOS/nixpkgs#509117).
  serviceDocModules =
    (import "${nixpkgsFlake}/nixos/modules/misc/documentation/modular-services.nix" {
      inherit lib;
      pkgs = nixpkgs;
    }).documentation.nixos.extraModules;

  # Evaluate base + service documentation modules together (service modules
  # depend on base option types). Then partition: options whose name starts
  # with "<" come from modular services.
  nixpkgsAllOpts = readNixOSOptions { module = nixpkgsBaseModules ++ serviceDocModules; };
  isServiceOption = opt: lib.hasPrefix "<" opt.name;
  readOptionsIf =
    {
      cond,
      reader,
    }:
    let
      check = lib.tryEval cond;
    in
    lib.optionals (check.success && check.value) reader;

in

rec {
  legacyPackages = legacyPackages' |> collectSystems "legacyPackages" |> lib.attrValues;
  packages = packages' |> collectSystems "packages" |> lib.attrValues;
  apps = apps' |> collectSystems "apps" |> lib.attrValues;
  options = readFlakeOptions;
  darwin-options = readOptionsIf {
    cond =
      lib.pathExists "${resolved}/modules/module-list.nix"
      && lib.pathExists "${resolved}/modules/system/defaults-write.nix";
    reader = readDarwinOptions;
  };
  home-manager-options = readOptionsIf {
    # Require both `modules/modules.nix` and `modules/lib/stdlib-extended.nix`
    # to avoid false positives. Other flakes (e.g. `nix-bitcoin`) ship a
    # `modules/modules.nix` that is unrelated to home-manager; only
    # home-manager itself also provides the `stdlib-extended.nix` helper
    # that `readHomeManagerOptions` imports.
    cond =
      lib.pathExists "${resolved}/modules/modules.nix"
      && lib.pathExists "${resolved}/modules/lib/stdlib-extended.nix";
    reader = readHomeManagerOptions;
  };
  all = packages ++ apps ++ options;

  # Partition options into standard NixOS options and modular service options in a single pass
  nixpkgsOptionsPartition = lib.partition isServiceOption nixpkgsAllOpts;
  nixos-options = nixpkgsOptionsPartition.wrong;

  # Parsed service options
  realServices = lib.filter (opt: opt ? service_package) (
    map parseServiceOption nixpkgsOptionsPartition.right
  );

  nixos-services = deduplicateServices realServices;

  # Map from package attribute name to the list of modular service module
  # names it exposes. Derived from the parsed service options above so it
  # stays in sync with nixpkgs' hand-maintained list.
  nixos-package-services = lib.zipAttrsWith (_: values: lib.unique values) (
    map (opt: { ${opt.service_package} = opt.service_module; }) realServices
  );
}
