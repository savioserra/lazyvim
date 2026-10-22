# The nix substrate's write plane: `workstation-switch` — the mutating
# operators (apply / rollback / update / sync) as thin wrappers around
# `home-manager switch` / `nixos-rebuild switch`.
#
# The seam law: nix owns the write plane end to end once proven on a
# real host; the daemon's own apply path retires only AFTER that proof,
# never here. This
# driver PROVES the replacement — every successful switch ends with the
# receipt publish (`workstation system applied`, the `system` overlay
# domain's wire op), which is how the daemon hears the switch.
#
# Home plane (default) wraps the user's `home-manager` profile; the
# `--system` flag wraps the host's `nixos-rebuild` profile (root runs it;
# the publish lands on the operator user's daemon — on single-user hosts
# run the publish as that user, e.g. `runuser -u <user> --`).
#
# Baked by the staging module (workstation-home.nix): the engine, the
# flake source snapshot THIS generation ships, and the two flake attrs.
# Environment overrides (the seams the VM E2E and CI use):
#   WORKSTATION_SWITCH_FLAKE          switch a different flake (e.g. a
#                                     writable checkout, for `update`)
#   WORKSTATION_SWITCH_HOME_ATTR      the homeConfiguration attr
#   WORKSTATION_SWITCH_SYSTEM_ATTR    the nixosConfiguration attr
#   WORKSTATION_SWITCH_HOME_ACTIVATE  replace the home-plane switch step
#                                     with a prebuilt activationPackage's
#                                     activate (offline hosts: the
#                                     evaluation already happened at
#                                     build time; `apply`/`sync` only)
{
  pkgs,
  engine,
  flake,
  homeAttr,
  systemAttr,
}:
let
  # The system-plane rebuild tool follows the DRIVER's platform: the
  # darwin-built driver wraps darwin-rebuild (the nix-darwin leg), the
  # Linux-built one wraps nixos-rebuild. Both use the `system` profile, so
  # the generation read after the switch is shared.
  rebuild = if pkgs.stdenv.isDarwin then "darwin-rebuild" else "nixos-rebuild";

  # The receipt: read the switched profile's generation and publish it on
  # the `system` domain. The profile link's tail IS the generation number
  # (home-manager-N-link / system-N-link) — the same source
  # `home-manager generations` reads, never a side-channel counter.
  readAndPublish = ''
    link="$(readlink "$profile" 2>/dev/null || true)"
    if [ -z "$link" ]; then
      echo "workstation-switch: no generation link at $profile — nothing published" >&2
      exit 1
    fi
    gen="''${link%-link}"
    gen="''${gen##*-}"
    if [ -z "$gen" ] || [ "''${gen//[0-9]/}" != "" ]; then
      echo "workstation-switch: no generation number in $link" >&2
      exit 1
    fi
    rollback=$((gen - 1))
    if [ "$rollback" -ge 1 ]; then
      exec "${engine}/bin/workstation" system applied --generation "$gen" --rollback-generation "$rollback"
    else
      exec "${engine}/bin/workstation" system applied --generation "$gen"
    fi
  '';
in
pkgs.writeShellScriptBin "workstation-switch" ''
  set -eu

  usage() {
    echo "usage: workstation-switch apply|rollback|update|sync [--system]" >&2
    exit 2
  }

  cmd="''${1:-}"
  [ -n "$cmd" ] || usage
  shift
  case "$cmd" in
    apply|rollback|sync|update) ;;
    *) usage ;;
  esac

  plane=home
  if [ "''${1:-}" = "--system" ]; then
    plane=system
    shift
  fi
  [ $# -eq 0 ] || usage

  flake="''${WORKSTATION_SWITCH_FLAKE:-${flake}}"
  home_attr="''${WORKSTATION_SWITCH_HOME_ATTR:-${homeAttr}}"
  system_attr="''${WORKSTATION_SWITCH_SYSTEM_ATTR:-${systemAttr}}"
  home_activate="''${WORKSTATION_SWITCH_HOME_ACTIVATE:-}"

  case "$plane:$cmd" in
    home:apply|home:sync)
      if [ -n "$home_activate" ]; then
        "$home_activate"
      else
        home-manager switch --flake "$flake#$home_attr"
      fi
      profile="''${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager"
      ;;
    home:rollback)
      home-manager rollback
      profile="''${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager"
      ;;
    home:update)
      nix flake update --flake "$flake"
      home-manager switch --flake "$flake#$home_attr"
      profile="''${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager"
      ;;
    system:apply|system:sync)
      ${rebuild} switch --flake "$flake#$system_attr"
      profile=/nix/var/nix/profiles/system
      ;;
    system:rollback)
      ${rebuild} switch --rollback
      profile=/nix/var/nix/profiles/system
      ;;
    system:update)
      nix flake update --flake "$flake"
      ${rebuild} switch --flake "$flake#$system_attr"
      profile=/nix/var/nix/profiles/system
      ;;
  esac

  # The publish replaces the process (exec): the driver's exit code IS the
  # receipt's — a refused publish fails the switch run loudly.
  ${readAndPublish}
''
