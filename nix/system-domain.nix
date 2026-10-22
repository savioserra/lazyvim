# The `system` overlay domain's publish contract — the NIX side of the
# two-reader drift guard.
#
# Every nix generation switch publishes "generation N applied (rollback
# available at N-1)" on the daemon's `system` overlay domain so both
# readers can subscribe: the daemon hears it over the existing wire
# protocol (the workstation-switch driver's publish step calls
# `workstation system applied`), and the evaluator reads THIS contract
# from the flake's eval report — byte-guarded against
# tests/nix/goldens/eval-report.json by .github/scripts/eval-goldens.sh,
# and cross-checked against the daemon's own constants by
# Workstation.Daemon.Capabilities.SystemTest (the golden is the shared
# pin between the two languages).
#
# Changing anything here is a deliberate golden re-record AND a daemon
# counterpart edit — neither reader can move alone.
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
