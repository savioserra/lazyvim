# The network domain's override: tailscale rides the foundation domain's
# toolchain input (the pinned set's daemon trails the tailnet's clients).
foundationPkgs: final: prev: {
  tailscale = foundationPkgs.tailscale;
}
