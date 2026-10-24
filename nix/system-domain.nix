# The `system` overlay domain's publish contract — the NIX side of the
# two-reader drift guard.
#
# Every nix generation switch publishes "generation N applied (rollback
# available at N-1)" on the daemon's `system` overlay domain so both
# readers can subscribe: the daemon hears it over the existing wire
# protocol (the workstation-switch driver's publish step calls
# `workstation system applied`), and the evaluator reads THIS contract
# from the flake's eval report (flake.evalReport — the same JSON the
# engine's release bakes), cross-checked against the daemon's own
# constants by Workstation.Daemon.Capabilities.SystemTest — the two
# readers' shared pin, enforced in code.
#
# Changing anything here is a deliberate counterpart edit on the daemon
# side — neither reader can move alone.
{
  domain = "system";
  op = "system.applied";
  eventType = "system.applied";
  messageFormat = "generation N applied (rollback available at M)";
  driver = {
    name = "workstation-switch";
    unit = "workstation-daemon.service";
    subcommands = [
      "apply"
      "rollback"
      "sync"
      "update"
    ];
  };
}
