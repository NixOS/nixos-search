{
  # Ensures no aliases are in the results.
  allowAliases = false;

  # Also list unfree packages
  allowUnfree = true;

  # Enable recursion into attribute sets that nix-env normally doesn't look into
  # so that we can get a more complete picture of the available packages for the
  # purposes of the index.
  packageOverrides = super:
  let
    recurseIntoAttrs = sets:
      super.lib.genAttrs
        (builtins.filter (set: builtins.hasAttr set super) sets)
        (set: super.recurseIntoAttrs (builtins.getAttr set super));
  in recurseIntoAttrs [
    "roundcubePlugins"
    "emscriptenfastcompPackages"
    "fdbPackages"
    "nodePackages_latest"
    "nodePackages"
    "platformioPackages"
    "haskellPackages"
    "haskell.compiler"
    "idrisPackages"
    "sconsPackages"
    "gns3Packages"
    "quicklispPackagesClisp"
    "quicklispPackagesSBCL"
    "rPackages"
    "apacheHttpdPackages_2_4"
    "zabbix44"
    "zabbix40"
    "zabbix30"
    "fusePackages"
    "nvidiaPackages"
    "sourceHanPackages"
    "atomPackages"
    "emacs25Packages"
    "emacs26Packages"
    "emacs25.pkgs"
    "emacs26.pkgs"
    "emacs27.pkgs"
    "steamPackages"
    "ut2004Packages"
    "zeroadPackages"
  ];
}
