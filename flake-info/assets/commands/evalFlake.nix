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

  statusFromStatuses =
    statuses:
    if statuses == [ ] then
      "passing"
    else if lib.all (status: status == "failing") statuses then
      "failing"
    else if lib.any (status: status != "passing") statuses then
      "partial"
    else
      "passing";

  safeValue =
    value:
    let
      result = lib.tryEval value;
    in
    if !result.success || lib.isFunction result.value then
      {
        success = false;
        value = null;
        status = "failing";
      }
    else if lib.isAttrs result.value then
      let
        namesResult = lib.tryEval (lib.attrNames result.value);
      in
      if !namesResult.success then
        {
          success = false;
          value = null;
          status = "failing";
        }
      else
        let
          children = map (name: safeValue result.value.${name}) namesResult.value;
        in
        {
          success = true;
          value = lib.listToAttrs (
            lib.zipListsWith (name: child: {
              inherit name;
              value = child.value;
            }) namesResult.value children
          );
          status = statusFromStatuses (map (child: child.status) children);
        }
    else if lib.isList result.value then
      let
        items = map safeValue result.value;
      in
      {
        success = true;
        value = map (item: item.value) items;
        status = statusFromStatuses (map (item: item.status) items);
      }
    else
      {
        success = true;
        inherit (result) value;
        status = "passing";
      };

  addStatus =
    status: value:
    value
    // {
      eval_status = status;
    }
    // lib.optionalAttrs (status != "passing") {
      reasons = [ "eval_failure" ];
    };

  evalMeta = meta: safeValue meta;

  evalDrvDynamic =
    drv:
    let
      namesResult = lib.tryEval (if lib.isAttrs drv then lib.attrNames drv else [ ]);
    in
    if !namesResult.success then
      {
        value = { };
        status = "failing";
      }
    else
      let
        fields = map (
          key:
          if !lib.elem key exportedDerivationKeys then
            null
          else
            let
              fieldResult = safeValue drv.${key};
              result = if key == "meta" && fieldResult.success then evalMeta fieldResult.value else fieldResult;
            in
            {
              inherit key result;
            }
        ) namesResult.value;
        fieldsWithValues = lib.filter (field: field != null) fields;
      in
      {
        value = lib.listToAttrs (
          map (field: {
            name = field.key;
            inherit (field.result) value;
          }) fieldsWithValues
        );
        status = statusFromStatuses (map (field: field.result.status) fieldsWithValues);
      };

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
      enrichItem =
        system: attrName: itemNode:
        let
          itemResult = safeValue itemNode;
          base = if itemResult.success then itemResult.value else { };
          result = lib.tryEval (
            let
              rawVal = lib.attrByPath (lib.splitString "." attrName) null (
                resolved.${schemaKey}.${system} or { }
              );
              val = if rawVal != null then rawVal else (base.value or base.derivation or base.app or null);
              isDrv = (lib.tryEval (lib.isDerivation val)).value or false;
              dynamic =
                if isDrv then
                  evalDrvDynamic val
                else
                  {
                    value = { };
                    status = "passing";
                  };
              status = statusFromStatuses [
                itemResult.status
                dynamic.status
              ];
            in
            {
              value = addStatus status (base // dynamic.value);
              inherit status;
            }
          );
        in
        if result.success then
          result.value
        else
          {
            value = addStatus "failing" base;
            status = "failing";
          };
    in
    if lib.attrNames inv == [ ] then
      { }
    else
      lib.mapAttrs (
        system: sysNode:
        if lib.isAttrs sysNode && sysNode ? children then
          let
            childrenResult = lib.tryEval sysNode.children;
            baseResult = safeValue (builtins.removeAttrs sysNode [ "children" ]);
            base = if baseResult.success then baseResult.value else { };
            childResults =
              if childrenResult.success then lib.mapAttrs (enrichItem system) childrenResult.value else { };
            childStatus =
              if childrenResult.success then
                statusFromStatuses (map (child: child.status) (lib.attrValues childResults))
              else
                "failing";
            status =
              if childStatus == "failing" then
                "failing"
              else if childStatus == "partial" || baseResult.status == "failing" then
                "partial"
              else
                "passing";
          in
          addStatus status (
            base
            // {
              children = lib.mapAttrs (_: child: child.value) childResults;
            }
          )
        else
          let
            baseResult = safeValue sysNode;
          in
          if baseResult.success then baseResult.value else { }
      ) inv;
in
{
  # Pure Nix-native flake-schemas evaluator (un-enriched, lazy)
  inventory = lib.mapAttrs (schemaKey: schemaDef: evalSchemaInventory schemaKey schemaDef) allSchemas;

  # Enriched JSON-serializable manifest evaluator for external consumers (enriched, eager)
  manifest = lib.mapAttrs (
    schemaKey: schemaDef: enrichSchemaInventory schemaKey schemaDef
  ) allSchemas;
}
