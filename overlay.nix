final: prev:
{
  nixos-search = {
    frontend = import ./. { pkgs = prev; };
    import_scripts = import ./import-scripts { pkgs = prev; };
    flake_info = import ./flake-info { pkgs = prev; };
  };
}
