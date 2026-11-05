# The 1Password CLI's unfree acceptance (allowUnfreePredicate), scoped to
# that one package and imported by every composition root: the report fold,
# the home configurations and the system legs.
{ lib }:
pkg: lib.getName pkg == "1password-cli"
