# The nunchux capability's override: fzf rides the foundation domain's
# toolchain input. The launcher is fzf's only consumer in the substrate.
foundationPkgs:
final: prev: {
  fzf = foundationPkgs.fzf;
}
