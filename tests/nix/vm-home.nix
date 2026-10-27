# The VM persona's declared home — the ONE body both consumers import:
# the boot-time home plane (vm-host.nix's home-manager.users.vm) and the
# standalone vm@vm configuration (flake.nix) that the E2E's apply-driven
# switch applies. Shared so the boot plane and the apply target can never
# drift.
{ ... }:
{
  home.username = "vm";
  home.homeDirectory = "/home/vm";
  # the switch driver's default targets inside the VM
  workstation.switch.homeAttr = "vm@vm";
  workstation.switch.systemAttr = "vm-test";
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
