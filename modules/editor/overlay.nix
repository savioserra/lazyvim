# The editor domain's overrides: neovim rides the domain's toolchain input
# (the pinned set predates the floor); its tree-sitter CLI is SCOPED -
# neovim links the pinned set's libtree-sitter, so nixpkgs' own
# tree-sitter name stays stock.
foundationPkgs:
final: prev: {
  neovim = foundationPkgs.neovim;
  workstation-tree-sitter = foundationPkgs.tree-sitter;
}
