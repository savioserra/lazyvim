# The foundation domain's floored tools: the pinned set lags the module's
# floors; the domain toolchain input carries the currency.
foundationPkgs:
final: prev: {
  fd = foundationPkgs.fd;
  ripgrep = foundationPkgs.ripgrep;
  lazygit = foundationPkgs.lazygit;
}
