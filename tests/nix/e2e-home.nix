# The E2E persona's declared home — the ONE body both consumers import:
# the container E2E's boot home and the standalone e2e@container
# configuration (flake.nix) that the apply-driven switch applies. Shared so
# the boot plane and the apply target can never drift.
{ ... }:
{
  home.username = "e2e";
  home.homeDirectory = "/home/e2e";
  # the switch driver's default for the container proof: the persona's own
  # home plane. No systemAttr — the container lane has no system plane (the
  # system gate is the toplevel drvPath eval), and the driver's fail-closed
  # guard is the designed behavior for a --system call with no target.
  workstation.switch.homeAttr = "e2e@container";
  # the E2E's profile-targeting proof: the declared skills also land in a
  # named profile's skills dir (a fresh profile sees the declared skills)
  programs.hermes.skills.secrets.profiles = [
    "default"
    "fresh"
  ];
  programs.hermes.skills.hsql.profiles = [
    "default"
    "fresh"
  ];
}
