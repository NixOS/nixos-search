import <nixpkgs/pkgs/top-level/packages-config.nix> // {
  # Do *NOT* list unfree packages
  allowUnfree = false;
}
