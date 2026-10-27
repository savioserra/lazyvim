# The mac host's retired-from-brew list: formulas brew used to own that
# the nix set now provides. This is OPERATOR DATA — extended on the mac
# host by `brew leaves` enumeration, one entry per formula moved to nix.
#
# The law (locked architecture fact): brew keeps ONLY casks (GUI apps).
# Every formula on this list must exist in the darwin configuration's nix
# set, or hosts/mac/default.nix's eval FAILS — a formula may never be
# retired from brew before nix provably owns it.
#
# Seeded from the workstation package tree's own pins: the terminal
# package's tmux and btop are nixpkgs-owned on the substrate (the mise
# toolchain lane is refused — nixpkgs provides the toolchains), so they
# lead the list.
[
  "tmux"
  "btop"
]
