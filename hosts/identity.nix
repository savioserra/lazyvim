# The machine's identity — captured ONCE by `workstation init` at install
# time. This committed copy is the TEMPLATE: the local rewrite stays
# uncommitted (the repo carries no personal strings at HEAD; evals run
# against the dirty working tree). Every consumer — tailscale, the
# dashboard binding, the rebuild keys — derives from this file.
{
  # shellExtras = "stty -ixon"; # optional: the operator's shell lines,
  # appended LAST in the managed rc lane (.bashrc/.zshrc) — absent or
  # empty renders no operator fragment
  host = "TEMPLATE"; # hostname -s
  user = "TEMPLATE"; # the operator user
  home = "/home/TEMPLATE"; # $HOME
}
