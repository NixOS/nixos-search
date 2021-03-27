{ flake }:
let
  resolved = builtins.getFlake (toString flake);

  lib = (import <nixpkgs> {}).lib;
  default = drv: attr: default: if drv ? ${attr} then drv.${attr} else default;

  # filter = lib.filterAttrs (key: _ : key == "apps" || key == "packages");

  withSystem = fn: lib.mapAttrs (system: drvs: (fn system drvs));
  readPackages = system: drvs: lib.mapAttrsToList (
    attribute_name: drv: (
      {
        attribute_name = attribute_name;
        system = system;
        name = drv.meta.name;
        # TODO consider using `builtins.parseDrvName`
        version = default drv "version" "";
        outputs = drv.outputs;
        # paths = builtins.listToAttrs ( map (output: {name = output; value = drv.${output};}) drv.outputs );
      }
      // lib.optionalAttrs (drv ? meta && drv.meta ? description) { inherit (drv.meta) description; }
      // lib.optionalAttrs (drv ? meta && drv.meta ? license) { inherit (drv.meta) license; }
    )
  ) drvs;

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


  packages' = lib.lists.flatten (lib.attrValues (withSystem readPackages (default resolved "packages" {})));

  apps' = lib.lists.flatten (lib.attrValues (withSystem readApps (default resolved "apps" {})));


  collectSystems = lib.lists.foldr (
    drv@{ attribute_name, system, ... }: set:
      let
        present = default set "${attribute_name}" ({ platforms = []; } // drv);

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
  packages = lib.attrValues (collectSystems packages');
  apps = lib.attrValues (collectSystems apps');
  all = packages ++ apps;
}
