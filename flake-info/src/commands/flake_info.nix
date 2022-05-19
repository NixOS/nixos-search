{ flake ? null }:
let
  resolved = builtins.getFlake "input-flake";

  nixpkgs = (import <nixpkgs> {});
  lib = nixpkgs.lib;

  # filter = lib.filterAttrs (key: _ : key == "apps" || key == "packages");

  withSystem = fn: lib.mapAttrs (system: drvs: (fn system drvs));
  isValid = d:
    let
      r = builtins.tryEval (lib.isDerivation d && ! (lib.attrByPath [ "meta" "broken" ] false d) &&
                            builtins.seq d.name true && d ? outputs);
    in
      r.success && r.value;
  validPkgs = lib.filterAttrs (k: v: isValid v);

  readPackages = system: drvs: lib.mapAttrsToList (
    attribute_name: drv: (
      {
        attribute_name = attribute_name;
        system = system;
        name = drv.name;
        # TODO consider using `builtins.parseDrvName`
        version = drv.version or "";
        outputs = drv.outputs;
        # paths = builtins.listToAttrs ( map (output: {name = output; value = drv.${output};}) drv.outputs );
        default_output = drv.outputName;
      }
      // lib.optionalAttrs (drv ? meta && drv.meta ? description) { inherit (drv.meta) description; }
      // lib.optionalAttrs (drv ? meta && drv.meta ? license) { inherit (drv.meta) license; }
    )
  ) (validPkgs drvs);
  readApps = system: apps: lib.mapAttrsToList (
    attribute_name: app: (
      {
        attribute_name = attribute_name;
        system = system;
      }
      // lib.optionalAttrs (app ? outPath) { bin = app.outPath; }
      // lib.optionalAttrs (app ? program) { bin = app.program; }
      // lib.optionalAttrs (app ? type) { type = app.type; }
    )
  ) apps;

  readOptions = let
    declarations = module: (
      lib.evalModules {
        modules = (if lib.isList module then module else [ module ]) ++ [
          (
            { ... }: {
              _module.check = false;
              nixpkgs.system = lib.mkDefault "x86_64-linux";
              nixpkgs.config.allowBroken = true;
            }
          )
        ];
      }
    ).options;

    cleanUpOption = extraAttrs: opt:
      let
        applyOnAttr = n: f: lib.optionalAttrs (builtins.hasAttr n opt) { ${n} = f opt.${n}; };
        mkDeclaration = decl:
          let
            discard = lib.concatStringsSep "/" (lib.take 4 (lib.splitString "/" decl)) + "/";
            path = if lib.hasPrefix builtins.storeDir decl then lib.removePrefix discard decl else decl;
          in
            path;

        # Replace functions by the string <function>
        substFunction = x:
          if builtins.isAttrs x then
             lib.mapAttrs (_:substFunction )  x
          else if builtins.isList x then
            map substFunction x
          else if lib.isFunction x then
            "function"
          else
             x;
      in
        opt
        // applyOnAttr "default" substFunction
        // applyOnAttr "example" substFunction # (_: { __type = "function"; })
        // applyOnAttr "type" substFunction
        // applyOnAttr "declarations" (map mkDeclaration)
        // extraAttrs;
  in
    { module, modulePath ? null }: let
      opts = lib.optionAttrSetToDocList (declarations module);
      extraAttrs = lib.optionalAttrs (modulePath != null) {
        flake = modulePath;
      };
    in
      map (cleanUpOption extraAttrs) (lib.filter (x: x.visible && !x.internal) opts);

  readFlakeOptions = let
    nixosModulesOpts = builtins.concatLists (lib.mapAttrsToList (moduleName: module:
      readOptions {
        inherit module;
        modulePath = [ flake moduleName ];
      }
    ) (resolved.nixosModules or {}));

    nixosModuleOpts = lib.optionals (resolved ? nixosModule) (
      readOptions {
        module = resolved.nixosModule;
        modulePath = [ flake ];
      }
    );
  in
    # We assume that `nixosModules` includes `nixosModule` when there
    # are multiple modules
    if nixosModulesOpts != [] then nixosModulesOpts else nixosModuleOpts;

  read = reader: set: lib.flatten (lib.attrValues (withSystem reader set));

  legacyPackages' = read readPackages (resolved.legacyPackages or {});
  packages' = read readPackages (resolved.packages or {});

  apps' = read readApps (resolved.apps or {});


  collectSystems = lib.lists.foldr (
    drv@{ attribute_name, system, ... }: set:
      let
        present = set."${attribute_name}" or ({ platforms = []; } // drv);

        drv' = present // {
          platforms = present.platforms ++ [ system ];
        };
        drv'' = removeAttrs drv' [ "system" ];
      in
        set // {
          ${attribute_name} = drv'';
        }
  ) {};

in

rec {
  legacyPackages = lib.attrValues (collectSystems legacyPackages');
  packages = lib.attrValues (collectSystems packages');
  apps = lib.attrValues (collectSystems apps');
  options = readFlakeOptions;
  all = packages ++ apps ++ options;

  # nixpkgs-specific, doesn't use the flake argument
  nixos-options = lib.mapAttrsToList (name: option: option // { inherit name; })
    (builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile
      "${(import <nixpkgs/nixos/release.nix> {}).options}/share/doc/nixos/options.json")));
}
