# The secrets domain's license acceptance, as a nixpkgs
# allowUnfreePredicate: the 1Password CLI is unfree upstream, and nixpkgs
# requires an explicit acceptance (operator ruling 2026-10-27 routes the
# CLI through nixpkgs). The acceptance lives here — named, scoped to the
# one package, imported by every composition root (the report fold's package
# set, the standalone home configurations, and the system legs) so no
# composition silently fails the eval or, worse, silently widens the
# acceptance.
{ lib }:
pkg: lib.getName pkg == "1password-cli"
