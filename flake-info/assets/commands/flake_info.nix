{
  targetFlake ? null,
  nixpkgsFlake ? builtins.getFlake "https://github.com/NixOS/nixpkgs/archive/refs/heads/nixpkgs-unstable.tar.gz",
  flake-schemas ? builtins.getFlake "github:DeterminateSystems/flake-schemas",
}:
let
  inherit (nixpkgsFlake.lib)
    attrByPath
    attrNames
    attrValues
    concatLists
    concatStringsSep
    drop
    elem
    elemAt
    filter
    findFirst
    groupBy
    hasPrefix
    head
    isAttrs
    isDerivation
    isFunction
    isList
    listToAttrs
    mapAttrs
    mapAttrsToList
    match
    mkForce
    naturalSort
    optionAttrSetToDocList
    optionalAttrs
    optionals
    partition
    pathExists
    removePrefix
    splitString
    tail
    toJSON
    tryEval
    unique
    zipAttrsWith
    ;

  resolved =
    if targetFlake == null then
      null
    else if isAttrs targetFlake then
      targetFlake
    else
      builtins.getFlake targetFlake;
  nixpkgs = nixpkgsFlake.legacyPackages.${referenceSystem};

  # Reference system to use for extracting full package metadata
  # For other systems, we only check attribute names to avoid redundant evaluation
  referenceSystem = "x86_64-linux";

  evalMetaDynamic =
    meta:
    let
      namesRes = tryEval (if isAttrs meta then attrNames meta else { });
    in
    if namesRes.success then
      listToAttrs (
        concatLists (
          map (
            key:
            let
              valRes = tryEval meta.${key};
            in
            if valRes.success && valRes.value != null then
              [
                {
                  name = key;
                  value = valRes.value;
                }
              ]
            else
              [ ]
          ) namesRes.value
        )
      )
    else
      { };

  evalDrvMetadata =
    drv:
    let
      derivResult = tryEval (isDerivation drv);
    in
    if derivResult.success && derivResult.value then
      let
        nameResult = tryEval drv.name;
        brokenResult = tryEval (drv.meta.broken or false);
        isBroken = brokenResult.success && brokenResult.value;
      in
      if nameResult.success && !isBroken then
        let
          versionResult = tryEval (drv.version or "");
          outputsResult = tryEval drv.outputs;
          outputNameResult = tryEval drv.outputName;
          metaDynamic = evalMetaDynamic (drv.meta or { });
        in
        {
          name = nameResult.value;
          version = if versionResult.success then versionResult.value else "";
          outputs = if outputsResult.success then outputsResult.value else [ "out" ];
          default_output = if outputNameResult.success then outputNameResult.value else "out";
          eval_status = "passing";
        }
        // metaDynamic
      else if isBroken then
        let
          versionResult = tryEval (drv.version or "");
          outputsResult = tryEval drv.outputs;
          outputNameResult = tryEval drv.outputName;
          descResult = tryEval (drv.meta.description or null);
        in
        {
          name = if nameResult.success then nameResult.value else drv.pname or "unnamed";
          version = if versionResult.success then versionResult.value else "";
          outputs = if outputsResult.success then outputsResult.value else [ "out" ];
          default_output = if outputNameResult.success then outputNameResult.value else "out";
          eval_status = "failing";
          reasons = [ "marked_broken" ];
        }
        // optionalAttrs (descResult.success && descResult.value != null) {
          description = descResult.value;
        }
      else if !nameResult.success then
        {
          name = drv.pname or "unnamed";
          eval_status = "failing";
          reasons = [ "eval_failure" ];
        }
      else
        null
    else
      null;

  getSchemaInventory =
    key:
    if resolved ? ${key} && schemas ? ${key} then
      let
        inv = tryEval (schemas.${key}.inventory resolved.${key});
      in
      if inv.success && inv.value ? children then inv.value.children else { }
    else
      { };

  evalPackageOrSet =
    system: attribute_name: val:
    let
      derivResult = tryEval (isDerivation val);
      isDrv = derivResult.success && derivResult.value;
    in
    if isDrv then
      if system == referenceSystem then
        let
          meta = evalDrvMetadata val;
        in
        if meta != null then
          [
            (
              {
                entry_type = "package";
                inherit attribute_name system;
              }
              // meta
            )
          ]
        else
          [
            {
              entry_type = "package";
              inherit attribute_name system;
              eval_status = "failing";
              reasons = [ "eval_failure" ];
            }
          ]
      else
        [
          {
            entry_type = "package";
            inherit attribute_name system;
            eval_status = "passing";
          }
        ]
    else if isAttrs val && (val.recurseForDerivations or false) then
      let
        attrRes = tryEval (attrNames val);
      in
      if attrRes.success then
        concatLists (
          map (
            child:
            if child == "recurseForDerivations" then
              [ ]
            else
              let
                childValRes = tryEval val.${child};
              in
              if childValRes.success && childValRes.value != null then
                evalPackageOrSet system "${attribute_name}.${child}" childValRes.value
              else
                [ ]
          ) attrRes.value
        )
      else
        [ ]
    else
      [ ];

  # Extract package and app entries using schema inventory functions
  readSchemaItems =
    schemaKey: entryType:
    concatLists (
      mapAttrsToList (
        system: sysNode:
        let
          # Forcing the per-system inventory node evaluates the flake's whole
          # output set for that system, which throws for e.g. a system nixpkgs
          # no longer supports. Skip that system rather than the whole flake.
          childrenResult = tryEval (sysNode.children or { });
        in
        concatLists (
          mapAttrsToList (
            attribute_name: itemNode:
            let
              res = tryEval (
                let
                  rawVal =
                    attrByPath (splitString "." attribute_name) null (resolved.${schemaKey}.${system} or { });
                  val = findFirst (x: x != null) rawVal [
                    (itemNode.value or null)
                    (itemNode.derivation or null)
                    (itemNode.app or null)
                  ];
                  binPathRes = tryEval (
                    itemNode.program or (if isAttrs val then (val.program or val.outPath or null) else null)
                  );
                  binPath = if binPathRes.success then binPathRes.value else null;
                in
                if entryType == "app" then
                  [
                    (
                      {
                        entry_type = "app";
                        inherit attribute_name system;
                        eval_status = if binPathRes.success then "passing" else "failing";
                      }
                      // optionalAttrs binPathRes.success { bin = binPath; }
                      // optionalAttrs (!binPathRes.success) { reasons = [ "eval_failure" ]; }
                      // optionalAttrs (itemNode ? type || (isAttrs val && val ? type)) {
                        type = itemNode.type or (if isAttrs val then val.type or "app" else "app");
                      }
                    )
                  ]
                else
                  evalPackageOrSet system attribute_name val
              );
            in
            if res.success then res.value else [ ]
          ) (if childrenResult.success then childrenResult.value else { })
        )
      ) (getSchemaInventory schemaKey)
    );

  legacyPackages' = readSchemaItems "legacyPackages" "package";
  packages' = readSchemaItems "packages" "package";
  apps' = readSchemaItems "apps" "app";

  # Replace functions by the string <function>
  substFunction =
    x:
    if isAttrs x then
      mapAttrs (_: substFunction) x
    else if isList x then
      map substFunction x
    else if isFunction x then
      "function"
    else
      x;

  # Strip store-path prefix from a declaration path
  mkDeclaration =
    decl:
    let
      parts = optionals (hasPrefix "${builtins.storeDir}/" decl) (
        tail (splitString "/" (removePrefix "${builtins.storeDir}/" decl))
      );
    in
    if parts != [ ] then concatStringsSep "/" parts else decl;

  # Clean up a raw option attrset for indexing
  cleanUpOption =
    extraAttrs: opt:
    let
      applyOnAttr = n: f: optionalAttrs (opt ? ${n}) { ${n} = f opt.${n}; };
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
  filterOptions = opts: filter (x: x.visible && !x.internal && head x.loc != "_module") opts;

  evalOptionsWith =
    {
      evalModules ? nixpkgsFlake.lib.evalModules, # some flakes provide their own evalModules function
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
              {
                _module.check = mkForce false;
              }
            ];
            specialArgs = {
              pkgs = nixpkgs;
            }
            // specialArgs;
          }
          // optionalAttrs (class != null) { inherit class; }
        )).options;

      opts = optionAttrSetToDocList declarations;
    in
    map (cleanUpOption extraAttrs) (filterOptions opts);

  readNixOSOptions =
    {
      module,
      modulePath ? null,
    }:
    evalOptionsWith {
      modules = if isList module then module else [ module ];
      specialArgs = {
        # !!! NixOS-specific. Unfortunately, NixOS modules can rely on the `modulesPath`
        # argument to import modules from the nixos tree. However, most of the time
        # this is done to import *profiles* which do not declare any options, so we
        # can allow it.
        modulesPath = "${nixpkgsFlake}/nixos/modules";
      };
      extraAttrs = optionalAttrs (modulePath != null) {
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
      m = match ".*imports.*pkgs\\.([^.]+)\\.services\\.([^ ]+).*>\\.(.*)" opt.name;
    in
    if m != null then
      opt
      // {
        entry_type = "service";
        name = elemAt m 2;
        service_package = elemAt m 0;
        service_module = elemAt m 1;
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
        toJSON [
          (opt.declarations or [ ])
          (opt.name or "")
          (opt.service_module or "")
        ];
      grouped = groupBy keyOf opts;
      mergeGroup =
        entries:
        let
          packages = naturalSort (unique (map (e: e.service_package or "") entries));
        in
        (head entries)
        // {
          service_package = head packages;
          service_packages = packages;
        };
    in
    mapAttrsToList (_: mergeGroup) grouped;

  # Base schemas from official flake-schemas input extended with custom schemas
  schemas = flake-schemas.exportedSchemas // (resolved.schemas or { });

  readFlakeOptions =
    let
      invModules = mapAttrs (
        name: n:
        if isFunction (n.value or n.module or null) || isAttrs (n.value or n.module or null) then
          n.value or n.module
        else
          resolved.nixosModules.${name} or n
      ) (getSchemaInventory "nixosModules");
      moduleSet = if invModules != { } then invModules else resolved.nixosModules or { };

      raw = concatLists (
        mapAttrsToList (
          moduleName: module:
          readNixOSOptions {
            inherit module;
            modulePath = [
              targetFlake
              moduleName
            ];
          }
        ) moduleSet
      );

      # When a flake re-exports the same module under multiple names
      # (e.g. `default` and `home-manager`), deduplicate by option name,
      # keeping the first occurrence.
      dedup = opts: attrValues (mapAttrs (_: head) (groupBy (opt: opt.name) opts));
    in
    dedup raw;

  # Extract options from home-manager's module system.
  # Evaluated separately during the nixpkgs channel import (via
  # `--arg targetFlake 'builtins.getFlake "github:nix-community/home-manager"'`) so that
  # home-manager options land in the channel index alongside NixOS options.
  readHomeManagerOptions =
    let
      # Home-manager modules use `lib.hm.*` helpers; extend nixpkgs' lib with
      # HM's custom library so module evaluation does not fail.
      hmLib = import "${resolved}/modules/lib/stdlib-extended.nix" nixpkgsFlake.lib;

      hmModulesPath = "${resolved}/modules/modules.nix";
      hmModuleList =
        let
          fn = import hmModulesPath;
        in
        if isFunction fn then
          fn {
            lib = hmLib;
            pkgs = nixpkgs;
          }
        else
          fn;
    in
    evalOptionsWith {
      inherit (hmLib) evalModules;
      modules = hmModuleList;
      extraAttrs = {
        entry_type = "home-manager-option";
      };
    };

  # Extract options from nix-darwin's module system.
  # Evaluated separately during the nixpkgs channel import (via
  # `--arg targetFlake 'builtins.getFlake "github:nix-darwin/nix-darwin"'`) so that
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
      grouped = groupBy (x: x.attribute_name) list;
      mergeEntry =
        attribute_name: entries:
        let
          firstWithMeta =
            let
              found = findFirst (e: e ? name || e ? bin) null entries;
            in
            if found != null then
              found
            else
              let
                firstEntry = head entries;
                meta = evaluatePackageFromSystem outputKey firstEntry.system attribute_name;
              in
              if meta != null then firstEntry // meta else firstEntry;

          targetOrder = [
            "x86_64-linux"
            "x86_64-darwin"
            "aarch64-linux"
            "aarch64-darwin"
          ];

          passingEntries = filter (e: (e.eval_status or "passing") == "passing") entries;
          failingEntries = filter (e: (e.eval_status or "passing") == "failing") entries;

          rawPlatforms = unique (map (e: e.system) passingEntries);
          platforms =
            (filter (x: elem x rawPlatforms) targetOrder) ++ (filter (x: !(elem x targetOrder)) rawPlatforms);

          hasPassing = passingEntries != [ ];
          hasFailing = failingEntries != [ ];

          overallStatus =
            if hasPassing && hasFailing then
              "partial"
            else if hasFailing then
              "failing"
            else
              "passing";

          platformStatus =
            if overallStatus == "partial" then
              listToAttrs (
                map (s: {
                  name = s;
                  value =
                    let
                      matching = findFirst (e: e.system == s) null entries;
                    in
                    if matching != null && (matching.eval_status or "passing") == "failing" then
                      {
                        status = "failing";
                        reason = head (matching.reasons or [ "eval_failure" ]);
                      }
                    else if matching != null then
                      { status = "passing"; }
                    else
                      {
                        status = "failing";
                        reason = "eval_failure";
                      };
                }) targetOrder
              )
            else
              null;
        in
        # A package that never evaluated on any system carries no `name`, which
        # `FlakeEntry::Package` requires -- keeping it fails deserialization for
        # the entire flake. Apps have no `name` by design, so this is restricted
        # to packages. Dropped by `collectSystemEntries`.
        if (firstWithMeta.entry_type or null) == "package" && !(firstWithMeta ? name) && overallStatus != "failing" then
          null
        else
          removeAttrs (
            firstWithMeta
            // {
              inherit platforms;
              eval_status = overallStatus;
            }
            // optionalAttrs (platformStatus != null) { platform_status = platformStatus; }
            // optionalAttrs (overallStatus == "failing" && firstWithMeta ? reasons) {
              reasons = firstWithMeta.reasons;
            }
          ) [ "system" ];
    in
    mapAttrs mergeEntry grouped;

  collectSystemEntries =
    outputKey: list: filter (x: x != null) (attrValues (collectSystems outputKey list));

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
      inherit (nixpkgsFlake) lib;
      pkgs = nixpkgs;
    }).documentation.nixos.extraModules;

  # Evaluate base + service documentation modules together (service modules
  # depend on base option types). Then partition: options whose name starts
  # with "<" come from modular services.
  nixpkgsAllOpts = readNixOSOptions { module = nixpkgsBaseModules ++ serviceDocModules; };
  isServiceOption = opt: hasPrefix "<" opt.name;
  readOptionsIf =
    {
      cond,
      reader,
    }:
    let
      check = tryEval cond;
    in
    optionals (check.success && check.value) reader;

in

rec {
  legacyPackages = collectSystemEntries "legacyPackages" legacyPackages';
  packages = collectSystemEntries "packages" packages';
  apps = collectSystemEntries "apps" apps';
  options = readFlakeOptions;
  darwin-options = readOptionsIf {
    cond =
      pathExists "${resolved}/modules/module-list.nix"
      && pathExists "${resolved}/modules/system/defaults-write.nix";
    reader = readDarwinOptions;
  };
  home-manager-options = readOptionsIf {
    # Require both `modules/modules.nix` and `modules/lib/stdlib-extended.nix`
    # to avoid false positives. Other flakes (e.g. `nix-bitcoin`) ship a
    # `modules/modules.nix` that is unrelated to home-manager; only
    # home-manager itself also provides the `stdlib-extended.nix` helper
    # that `readHomeManagerOptions` imports.
    cond =
      pathExists "${resolved}/modules/modules.nix"
      && pathExists "${resolved}/modules/lib/stdlib-extended.nix";
    reader = readHomeManagerOptions;
  };
  all = legacyPackages ++ packages ++ apps ++ options;

  # Partition options into standard NixOS options and modular service options in a single pass
  nixpkgsOptionsPartition = partition isServiceOption nixpkgsAllOpts;
  nixos-options = nixpkgsOptionsPartition.wrong;

  # Parsed service options
  realServices = filter (opt: opt ? service_package) (
    map parseServiceOption nixpkgsOptionsPartition.right
  );

  nixos-services = deduplicateServices realServices;

  # Map from package attribute name to the list of modular service module
  # names it exposes. Derived from the parsed service options above so it
  # stays in sync with nixpkgs' hand-maintained list.
  nixos-package-services = zipAttrsWith (_: values: unique values) (
    map (opt: { ${opt.service_package} = opt.service_module; }) realServices
  );
}
