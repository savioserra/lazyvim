# The machine's identity — captured ONCE by `workstation init` at install
# time. This committed copy is the TEMPLATE (the TEMPLATE placeholders):
# the local rewrite stays uncommitted (the repo carries no personal strings
# at HEAD; evals run against the dirty working tree). Every consumer —
# tailscale, the dashboard binding, the rebuild keys — derives from this
# file. `workstation init` MERGES on a re-run: a field you set here wins
# over the detected default; only the placeholders below are filled.
{
  host = "TEMPLATE"; # captured by workstation init (hostname -s)
  user = "TEMPLATE"; # captured by workstation init (the operator user)
  home = "/home/TEMPLATE"; # captured by workstation init ($HOME)
  # shellExtras = "stty -ixon"; # optional: the operator's shell lines,
  # appended LAST in the managed rc lane (.bashrc/.zshrc) — absent or
  # empty renders no operator fragment; once set here it survives every
  # re-init (the merge never touches a field you set)
  # tailscaleFqdn = ""; # optional: the host's MagicDNS name — the fleet
  # transport and host-binding consumers derive from it when set
}
