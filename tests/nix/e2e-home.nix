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
  # the operator's shell extras (the stty -ixon class): the persona
  # declares them, so the lane renders its LAST fragment (operator-extras,
  # slot 100, .bashrc/.zshrc) and the apply-driven switch re-renders it —
  # the container proof covers the option's non-empty form (the template's
  # empty default renders no fragment; the vps identity is the real-world
  # shape of this line)
  workstation.foundation.shell.extras = "stty -ixon";
}
