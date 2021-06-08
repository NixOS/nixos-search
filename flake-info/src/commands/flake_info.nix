{ flake }:
let
  resolved = builtins.getFlake (toString flake);

  lib = (import <nixpkgs> {}).lib;
  default = drv: attr: default: if drv ? ${attr} then drv.${attr} else default;

  # filter = lib.filterAttrs (key: _ : key == "apps" || key == "packages");

  withSystem = fn: lib.mapAttrs (system: drvs: (fn system drvs));
      isValid = d:
        let r = builtins.tryEval (lib.isDerivation d && ! (lib.attrByPath [ "meta" "broken" ] false d) && builtins.seq d.name true &&  d ? outputs);
        in r.success && r.value;
  all = pkgs:
    let
      validPkgs = lib.filterAttrs (k: v: isValid v) pkgs;
    in validPkgs;

  readPackages = system: drvs:  lib.mapAttrsToList (
    attribute_name: drv: (
      # if isValid drv then
      {
        attribute_name = attribute_name;
        system = system;
        name = drv.name;
        # TODO consider using `builtins.parseDrvName`
        version = default drv "version" "";
        outputs = drv.outputs;
        # paths = builtins.listToAttrs ( map (output: {name = output; value = drv.${output};}) drv.outputs );
      }
      // lib.optionalAttrs (drv ? meta && drv.meta ? description) { inherit (drv.meta) description; }
      // lib.optionalAttrs (drv ? meta && drv.meta ? license) { inherit (drv.meta) license; }

      # else {}
    )
  ) (all drvs);

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


  read = reader: set: lib.lists.flatten (lib.attrValues (withSystem reader set));

  legacyPackages' = read readPackages (default resolved "legacyPackages" {});
  packages' = read readPackages (default resolved "packages" {});

  apps' = read readApps (default resolved "apps" {});


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
  legacyPackages = lib.attrValues (collectSystems legacyPackages');
  packages = lib.attrValues (collectSystems packages');
  apps = lib.attrValues (collectSystems apps');
  all = packages ++ apps;
}
