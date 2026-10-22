# The omarchy leg's host-specific home module: what omarchy (Arch +
# Hyprland) needs BEYOND the shared workstation-home substrate.
#
# Deliberately minimal: the substrate (file plane, fragment plane, daemon
# user unit, nvim profile lane, workstation-switch driver) is fully
# rendered by workstation-home.nix from the package tree. This module only
# carries the Arch-host facts nix cannot derive from the tree:
#
#   - fonts: omarchy's Hyprland session needs fontconfig discovery just
#     like the NixOS leg; already enabled by the shared module, so nothing
#     to add here.
#   - the daemon user unit ships through HM's
#     ~/.config/systemd/user (the shared module); on Arch it starts with
#     `systemctl --user enable --now workstation-daemon` — the operator
#     step named in hosts/omarchy/README.md. HM cannot enable it on a
#     foreign distro's user manager without loginctl glue, so this stays
#     an explicit apply step, not hidden automation.
#
# NOTE: no NixOS flip here — the NixOS migration on Arch hosts is
# deferred by operator ruling (2026-10-21).
{
  config,
  lib,
  pkgs,
  ...
}:
{
  # omarchy's shell sessions source the fragment lane via the shared rc
  # contract; nothing Arch-specific overrides the manifests. The module
  # exists so the host leg has a named home and a place for the first
  # omarchy-only deviation, instead of growing conditionals inside the
  # shared substrate module.
}
