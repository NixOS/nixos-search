{
  targetFlake,
  nixpkgs,
  flake-schemas,
}:
let
  inherit (nixpkgs) lib;

  resolved = if lib.isAttrs targetFlake then targetFlake else builtins.getFlake targetFlake;

  allSchemas = flake-schemas.schemas // (resolved.schemas or resolved.exportedSchemas or { });

  exportedDerivationKeys = [
    "name"
    "pname"
    "version"
    "outputs"
    "outputName"
    "system"
    "meta"
  ];

  evalMeta =
    meta:
    let
      namesRes = lib.tryEval (if lib.isAttrs meta then lib.attrNames meta else [ ]);
    in
    if namesRes.success then
      lib.listToAttrs (
        lib.concatLists (
          map (
            key:
            let
              valRes = lib.tryEval meta.${key};
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

  evalDrvDynamic =
    drv:
    let
      namesRes = lib.tryEval (if lib.isAttrs drv then lib.attrNames drv else [ ]);
    in
    if namesRes.success then
      lib.listToAttrs (
        lib.concatLists (
          map (
            key:
            if !lib.elem key exportedDerivationKeys then
              [ ]
            else
              let
                valRes = lib.tryEval drv.${key};
              in
              if valRes.success && valRes.value != null then
                [
                  {
                    name = key;
                    value = if key == "meta" then evalMeta valRes.value else valRes.value;
                  }
                ]
              else
                [ ]
          ) namesRes.value
        )
      )
    else
      { };

  evalSchemaInventory =
    schemaKey: schemaDef:
    if resolved ? ${schemaKey} && schemaDef ? inventory then
      let
        invRes = lib.tryEval (schemaDef.inventory resolved.${schemaKey});
      in
      if invRes.success && invRes.value ? children then invRes.value.children else { }
    else
      { };

  enrichSchemaInventory =
    schemaKey: schemaDef:
    let
      inv = evalSchemaInventory schemaKey schemaDef;
    in
    if inv == { } then
      { }
    else
      lib.mapAttrs (
        system: sysNode:
        if lib.isAttrs sysNode && sysNode ? children then
          sysNode
          // {
            children = lib.mapAttrs (
              attrName: itemNode:
              let
                rawVal = lib.attrByPath (lib.splitString "." attrName) null (
                  resolved.${schemaKey}.${system} or { }
                );
                val =
                  if rawVal != null then rawVal else (itemNode.value or itemNode.derivation or itemNode.app or null);
                isDrv = (lib.tryEval (lib.isDerivation val)).value or false;
                drvMeta = if isDrv then evalDrvDynamic val else { };
              in
              itemNode // drvMeta
            ) sysNode.children;
          }
        else
          sysNode
      ) inv;

  # Pure Nix-native flake-schemas evaluator (un-enriched, lazy)
  inventory = lib.mapAttrs (schemaKey: schemaDef: evalSchemaInventory schemaKey schemaDef) allSchemas;

  # Enriched JSON-serializable manifest evaluator for external consumers (enriched, eager)
  manifest = lib.mapAttrs (
    schemaKey: schemaDef: enrichSchemaInventory schemaKey schemaDef
  ) allSchemas;
in
{
  inherit inventory manifest;
}
