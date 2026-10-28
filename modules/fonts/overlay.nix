# The fonts domain's override: the nerd-fonts set rides the foundation
# domain's toolchain input (version currency for the JetBrainsMono tree).
foundationPkgs:
final: prev: {
  nerd-fonts = foundationPkgs.nerd-fonts;
}
