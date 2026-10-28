# The secrets domain's override: the 1Password CLI (unfree - rides the
# foundation input's import, which carries the license acceptance).
foundationPkgs:
final: prev: {
  _1password-cli = foundationPkgs._1password-cli;
}
