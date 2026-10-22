# The omarchy leg (Arch + Hyprland, standalone home-manager)

The substrate renders on Arch through the SAME standalone-HM shape as the
WSL leg: nix itself stages everything, the package tree stays the one
source, and the daemon runs as a systemd user unit inside omarchy's user
manager. No NixOS flip — deferred by operator ruling (2026-10-21).

The rebuild key is DERIVED from `hosts/omarchy/default.nix`'s identity
block (`${user}@omarchy`) — that file is the only place the host's user
lives; flip `user` there and every path/key follows.

## Apply (on the Arch host)

```sh
# one-time: nix + home-manager available (omarchy ships nix on recent
# images; otherwise the upstream installer). From a clone of the
# program's anchor repo (the nix substrate remote):
nix build .#homeConfigurations.\"<user>@omarchy\".activationPackage
./result/activate

# the daemon user unit (ships through ~/.config/systemd/user):
systemctl --user daemon-reload
systemctl --user enable --now workstation-daemon

# the mutating seam:
workstation-switch apply    # home-manager switch + the `system` domain receipt
```

## Proof status (2026-10-22)

- eval green: `homeConfigurations."omarchy@omarchy"` (activationPackage +
  report) — same standalone-HM shape the WSL leg ships.
- consumer smoke + live apply: NOT run — the Arch host was unreachable
  from the runner (ssh `linux`: name resolution failure; re-verified
  2026-10-22). The same substrate shape IS consumer-smoked live inside
  the NixOS VM (`tests/nix/run-vm.sh`: daemon user unit, wire handshake,
  apply-driven switch, journal receipt), so the seam is proven; the Arch
  apply is the operator's cutover step.
