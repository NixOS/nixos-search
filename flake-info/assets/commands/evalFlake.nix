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

  mkFailure = kind: {
    path = [ ];
    inherit kind;
  };

  prependFailurePath =
    path: failure:
    failure
    // {
      path = path ++ failure.path;
    };

  safeValue =
    value:
    let
      result = lib.tryEval value;
      failure = mkFailure "evaluation_failure";
    in
    if !result.success || lib.isFunction result.value then
      {
        success = false;
        value = null;
        status = "failing";
        failures = [ failure ];
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
          failures = [ failure ];
        }
      else
        let
          children = map (name: {
            inherit name;
            result = safeValue result.value.${name};
          }) namesResult.value;
        in
        {
          success = true;
          value = lib.listToAttrs (
            map (child: {
              name = child.name;
              value = child.result.value;
            }) children
          );
          status = statusFromStatuses (map (child: child.result.status) children);
          failures = lib.concatLists (
            map (child: map (prependFailurePath [ child.name ]) child.result.failures) children
          );
        }
    else if lib.isList result.value then
      let
        items = map safeValue result.value;
      in
      {
        success = true;
        value = map (item: item.value) items;
        status = statusFromStatuses (map (item: item.status) items);
        failures = lib.concatLists (
          lib.imap0 (index: item: map (prependFailurePath [ index ]) item.failures) items
        );
      }
    else
      {
        success = true;
        inherit (result) value;
        status = "passing";
        failures = [ ];
      };

  addEvaluation =
    status: failures: value:
    if status == "passing" then
      value
    else
      (if lib.isAttrs value then value else { value = value; })
      // {
        # see https://github.com/DeterminateSystems/flake-schemas/issues/65
        __evaluation = {
          inherit status failures;
        };
      };

  evalDrvDynamic =
    drv:
    let
      namesResult = lib.tryEval (if lib.isAttrs drv then lib.attrNames drv else [ ]);
    in
    if !namesResult.success then
      {
        value = { };
        status = "failing";
        failures = [ (mkFailure "evaluation_failure") ];
      }
    else
      let
        fields = map (
          key:
          if !lib.elem key exportedDerivationKeys then
            null
          else
            {
              inherit key;
              result = safeValue drv.${key};
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
        failures = lib.concatLists (
          map (field: map (prependFailurePath [ field.key ]) field.result.failures) fieldsWithValues
        );
      };

  evalAppDynamic =
    app:
    let
      appResult = lib.tryEval app;
      metadataResult =
        if appResult.success && lib.isAttrs appResult.value then
          safeValue (
            removeAttrs appResult.value [
              "program"
              "bin"
            ]
          )
        else
          {
            success = false;
            value = { };
            status = "failing";
            failures = [ (mkFailure "evaluation_failure") ];
          };
      programResult =
        if appResult.success && lib.isAttrs appResult.value then
          safeValue (appResult.value.program or appResult.value.bin or null)
        else
          {
            success = false;
            value = null;
            status = "failing";
            failures = [ (mkFailure "evaluation_failure") ];
          };
      programStatus =
        if programResult.success && lib.isString programResult.value then "passing" else "failing";
      programFailures =
        if programResult.success && lib.isString programResult.value then
          [ ]
        else if programResult.failures == [ ] then
          [ (mkFailure "invalid_type") ]
        else
          programResult.failures;
      status = if programStatus == "failing" then "failing" else metadataResult.status;
    in
    {
      value = {
        bin = if programStatus == "passing" then programResult.value else null;
      };
      inherit status;
      failures = metadataResult.failures ++ map (prependFailurePath [ "bin" ]) programFailures;
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
                if schemaKey == "apps" then
                  evalAppDynamic val
                else if isDrv then
                  evalDrvDynamic val
                else
                  {
                    value = { };
                    status = "passing";
                    failures = [ ];
                  };
              status =
                if schemaKey == "apps" && dynamic.status == "failing" then
                  "failing"
                else
                  statusFromStatuses [
                    itemResult.status
                    dynamic.status
                  ];
              failures = itemResult.failures ++ dynamic.failures;
            in
            {
              value = addEvaluation status failures (base // dynamic.value);
              inherit status failures;
            }
          );
        in
        if result.success then
          result.value
        else
          {
            value = addEvaluation "failing" [ (mkFailure "evaluation_failure") ] base;
            status = "failing";
            failures = [ (mkFailure "evaluation_failure") ];
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
            failures =
              (if baseResult.success then baseResult.failures else [ (mkFailure "evaluation_failure") ])
              ++ (
                if childrenResult.success then
                  lib.concatLists (
                    lib.mapAttrsToList (
                      childName: child:
                      map (prependFailurePath [
                        "children"
                        childName
                      ]) child.failures
                    ) childResults
                  )
                else
                  [ (mkFailure "evaluation_failure") ]
              );
          in
          addEvaluation status failures (
            base
            // {
              children = lib.mapAttrs (_: child: child.value) childResults;
            }
          )
        else
          let
            baseResult = safeValue sysNode;
          in
          if baseResult.success then
            addEvaluation baseResult.status baseResult.failures baseResult.value
          else
            addEvaluation "failing" baseResult.failures { }
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
