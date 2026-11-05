# The unfree acceptance: the 1Password CLI only.
{ lib }:
pkg: lib.getName pkg == "1password-cli"
