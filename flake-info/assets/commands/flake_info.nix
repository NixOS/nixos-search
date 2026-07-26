{
  targetFlake ? null,
  nixpkgsFlake ? builtins.getFlake "https://github.com/NixOS/nixpkgs/archive/refs/heads/nixpkgs-unstable.tar.gz",
  flake-schemas ? builtins.getFlake "github:DeterminateSystems/flake-schemas",
}:
let
  inherit (nixpkgsFlake) lib;
  resolved = if targetFlake != null then builtins.getFlake targetFlake else null;
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
    lib.concatLists (
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

  evalModulesWith =
    {
      evalModules ? lib.evalModules,
      modules,
      specialArgs ? { },
      class ? null,
    }:
    evalModules (
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
    );

  # Turn an evaluation's option set into the flat, indexable list of options
  docListOf =
    extraAttrs: eval:
    map (cleanUpOption extraAttrs) (filterOptions (lib.optionAttrSetToDocList eval.options));

  evalOptionsWith =
    {
      extraAttrs ? { },
      ...
    }@args:
    docListOf extraAttrs (evalModulesWith (removeAttrs args [ "extraAttrs" ]));

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
              targetFlake
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
  # `--arg targetFlake 'builtins.getFlake "github:nix-community/home-manager"'`) so that
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

  # Kept in sync with `undocumented` in nixpkgs'
  # nixos/modules/misc/documentation/modular-services.nix: a fixture for
  # nixos/tests/modular-service-etc rather than a service anyone would import.
  undocumentedServices = [ "python-http-server" ];

  serviceRegistryPath = "${nixpkgsFlake}/nixos/modules/system/service/modular/default.nix";

  # Discovery from nixpkgs' modular service registry, which enumerates every
  # `<environment>.<package>.<service>` variant. `module` is the variant a
  # NixOS configuration actually gets.
  registryServices =
    let
      modularServices = (import "${nixpkgsFlake}/nixos/lib" { }).modularServices;

      flat = lib.concatLists (
        lib.mapAttrsToList (
          environment: packages:
          lib.concatLists (
            lib.mapAttrsToList (
              package: services:
              lib.mapAttrsToList (service: module: {
                inherit
                  environment
                  package
                  service
                  module
                  ;
              }) services
            ) packages
          )
        ) modularServices
      );

      grouped = lib.groupBy (x: "${x.package}.${x.service}") (
        lib.filter (x: !(lib.elem x.package undocumentedServices)) flat
      );

      # Every environment the registry knows about, so a service can report the
      # ones it does *not* support alongside the ones it does.
      knownEnvironments = lib.attrNames modularServices;
    in
    lib.mapAttrsToList (
      _: entries:
      let
        registered = lib.listToAttrs (map (x: lib.nameValuePair x.environment x.module) entries);

        environments = map (name: {
          inherit name;
          supported = registered ? ${name};
          module = registered.${name} or null;
        }) knownEnvironments;
      in
      {
        inherit (lib.head entries) package service;
        module = (primaryEnvironment environments).module;
        inherit environments;
      }
    ) grouped;

  # Discovery on nixpkgs revisions that predate the registry: nixpkgs' own
  # documentation module is hand-maintained there, so harvest the service
  # names it declares. Before the split the portable module *was* the NixOS
  # module, so there is no separate environment half -- `module = null` marks
  # that, and keeps environment-specific maintainers empty rather than
  # duplicating the base half's.
  legacyServices =
    let
      docModules =
        (import "${nixpkgsFlake}/nixos/modules/misc/documentation/modular-services.nix" {
          inherit lib;
          pkgs = nixpkgs;
        }).documentation.nixos.extraModules;

      names = lib.concatMap (module: lib.attrNames (module.options or { })) docModules;

      parse =
        name:
        let
          # `\]` is not a valid POSIX ERE escape; an unpaired `]` is literal.
          m = lib.match "<imports = \\[ pkgs\\.([^.]+)\\.services\\.([^ ]+) ]>" name;
        in
        if m == null then
          null
        else
          {
            package = lib.elemAt m 0;
            service = lib.elemAt m 1;
          };
    in
    map
      (
        entry:
        entry
        // {
          module = nixpkgs.${entry.package}.services.${entry.service};
          environments = [
            {
              name = "system";
              supported = true;
              module = null;
            }
          ];
        }
      )
      (
        lib.filter (entry: entry != null && !(lib.elem entry.package undocumentedServices)) (
          map parse names
        )
      );

  # [ { package; service; module; environments = [ { name; supported; module; } ]; } ]
  #
  # `environments` lists every environment the registry knows, not just the ones
  # this service is registered for; `supported` tells them apart.
  serviceRegistry = if lib.pathExists serviceRegistryPath then registryServices else legacyServices;

  # The environment a NixOS configuration gets, falling back to whichever
  # supported environment happens to be registered first.
  primaryEnvironment =
    environments:
    let
      supported = lib.filter (env: env.supported) environments;
    in
    lib.findFirst (env: env.name == "system") (lib.head supported) supported;

  # The portable half, which every environment builds on.
  baseImportOf = e: "pkgs.${e.package}.services.${e.service}";

  # The registry names environments but does not carry the option that exposes
  # them, so this is a small lookup. Falls back to the portable module for
  # environments we do not know an accessor for, and for nixpkgs revisions
  # that predate the split.
  environmentAccessors = {
    system = "config.modularServices";
  };

  # `null` for an environment the service is not registered for: there is
  # nothing to import there.
  envImportOf =
    e: env:
    if !env.supported then
      null
    else if env.module != null && environmentAccessors ? ${env.name} then
      "${environmentAccessors.${env.name}}.${e.package}.${e.service}"
    # Do not merge these branches: the accessor is per environment, the
    # portable half is not.
    else
      baseImportOf e;

  primaryImportOf = e: envImportOf e (primaryEnvironment e.environments);

  # Option names are keyed by an import expression we generate ourselves, so
  # the prefix is an exact key rather than something to parse back out.
  serviceOptionPrefix = e: "<imports = [ ${primaryImportOf e} ]>";
  serviceByPrefix = lib.listToAttrs (
    map (e: lib.nameValuePair (serviceOptionPrefix e) e) serviceRegistry
  );
  isServiceOption = opt: serviceByPrefix ? ${lib.head opt.loc};

  # Mirrors `fakeSubmodule` in nixpkgs'
  # nixos/modules/misc/documentation/modular-services.nix. `pkgs` has to be a
  # special argument: a variant reaches its portable half through
  # `imports = [ pkgs.<pkg>.services.<svc> ]`, which is evaluated before
  # `_module.args`.
  fakeServiceSubmodule =
    module:
    lib.mkOption {
      type = lib.types.submoduleWith {
        specialArgs = {
          pkgs = nixpkgs;
        };
        modules = [ module ];
      };
      description = "This is a [modular service](https://nixos.org/manual/nixos/unstable/#modular-services), which can be imported into a NixOS configuration using the [`system.services`](https://search.nixos.org/options?channel=unstable&show=system.services&query=modular+service) option.";
    };

  serviceOptionsModule = {
    options = lib.listToAttrs (
      map (e: lib.nameValuePair (serviceOptionPrefix e) (fakeServiceSubmodule e.module)) serviceRegistry
    );
  };

  serviceKey = e: "${e.package}.${e.service}";

  # Attaching the services as real configuration makes their `meta.maintainers`
  # readable. It declares no options, and laziness keeps everything but
  # `meta.maintainers` unevaluated.
  serviceAttachModule = {
    system.services = lib.listToAttrs (
      map (e: lib.nameValuePair (serviceKey e) { imports = [ e.module ]; }) serviceRegistry
    );
  };

  # Evaluate base + service modules together (service modules depend on base
  # option types).
  nixpkgsEval = evalModulesWith {
    modules = nixpkgsBaseModules ++ [
      serviceOptionsModule
      serviceAttachModule
    ];
    specialArgs = {
      # !!! NixOS-specific, see `readNixOSOptions`.
      modulesPath = "${nixpkgsFlake}/nixos/modules";
    };
  };

  nixpkgsAllOpts = docListOf { } nixpkgsEval;

  # `meta.maintainers` merges to an attrset of defining file -> maintainer list
  # (nixpkgs' modules/generic/meta-maintainers.nix), so a service's maintainers
  # arrive already split by the half that declared them.
  maintainersBySource =
    e:
    let
      result = safeEval (nixpkgsEval.config.system.services.${serviceKey e}.meta.maintainers or { });
      raw = if result.success && lib.isAttrs result.value then result.value else { };
    in
    lib.filterAttrs (
      file: maintainers:
      # A lone empty list is the option's `default` attributed to its declaring
      # file, not a maintainer claim.
      maintainers != [ ]
      # A module that lost its `_file` is attributed to wherever the
      # `deferredModule` was defined, so its provenance is unknown. That is a
      # nixpkgs bug, guarded upstream by `nixosTests.modularServiceVariants`.
      && !(lib.hasInfix ", via option " file)
      # The file that *declares* `meta.maintainers` is imported by every module
      # system that offers the option, so where it still names maintainers of
      # its own they belong to that file rather than to any service.
      && file != maintainerOptionFile
    ) (lib.mapAttrs' (file: maintainers: lib.nameValuePair (mkDeclaration file) maintainers) raw);

  maintainerOptionFile = "modules/generic/meta-maintainers.nix";

  projectMaintainer =
    m:
    lib.optionalAttrs (m ? name) { inherit (m) name; }
    // lib.optionalAttrs (m ? email) { inherit (m) email; }
    // lib.optionalAttrs (m ? github) { inherit (m) github; };

  # Per-service indexed fields, derived once per service and shared by all of
  # its options.
  serviceInfo =
    e:
    let
      bySource = maintainersBySource e;
      sourceOf = env: if env.module == null then null else mkDeclaration (toString env.module);
      environmentSources = lib.filter (x: x != null) (map sourceOf e.environments);
    in
    {
      service_package = e.package;
      service_module = e.service;
      service_import = baseImportOf e;
      # Every known environment, so the frontend can show which ones a service
      # does not support. Unsupported ones carry no import and no maintainers.
      service_environments = map (
        env:
        {
          environment = env.name;
          inherit (env) supported;
        }
        // lib.optionalAttrs env.supported {
          import = envImportOf e env;
          maintainers = map projectMaintainer (
            let
              source = sourceOf env;
            in
            if source == null then [ ] else bySource.${source} or [ ]
          );
        }
      ) e.environments;
      service_maintainers = map projectMaintainer (
        lib.concatLists (
          lib.attrValues (lib.filterAttrs (file: _: !(lib.elem file environmentSources)) bySource)
        )
      );
    };

  serviceInfoByPrefix = lib.mapAttrs (_: serviceInfo) serviceByPrefix;

  # Strip the generated prefix and attach the service's metadata. The entry
  # whose name *is* the prefix is the submodule root rather than an option.
  parseServiceOption =
    opt:
    let
      prefix = lib.head opt.loc;
    in
    opt
    // {
      entry_type = "service";
      name = lib.removePrefix "${prefix}." opt.name;
    }
    // serviceInfoByPrefix.${prefix};

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
  legacyPackages = lib.attrValues (collectSystems "legacyPackages" legacyPackages');
  packages = lib.attrValues (collectSystems "packages" packages');
  apps = lib.attrValues (collectSystems "apps" apps');
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

  # A single-element `loc` is the submodule root itself rather than one of the
  # service's options.
  nixos-services = map parseServiceOption (
    lib.filter (opt: lib.length opt.loc > 1) nixpkgsOptionsPartition.right
  );

  # Map from package attribute name to the list of modular service names it
  # exposes.
  nixos-package-services = lib.zipAttrsWith (_: lib.unique) (
    map (e: { ${e.package} = e.service; }) serviceRegistry
  );

  # Per-package service metadata: import expressions, environment support and
  # each half's maintainers. The package page is where a modular service is
  # described as a whole, so it carries what the option pages link out to.
  nixos-package-service-imports = lib.zipAttrsWith (_: values: values) (
    map (
      e:
      let
        info = serviceInfo e;
      in
      {
        ${e.package} = {
          service = e.service;
          import = info.service_import;
          maintainers = info.service_maintainers;
          environments = info.service_environments;
        };
      }
    ) serviceRegistry
  );
}
