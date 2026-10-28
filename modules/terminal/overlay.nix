# The terminal domain's overrides: the ls replacement (eza) rides the
# domain toolchain input for version currency.
foundationPkgs:
final: prev: {
  eza = foundationPkgs.eza;
}
