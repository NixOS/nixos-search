final: prev: {
  nixos-search = {
    frontend = import ./frontend { pkgs = prev; };
    flake-info = import ./flake-info { pkgs = prev; };
  };
}
