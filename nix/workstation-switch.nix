# The nix substrate's write plane: `workstation-switch` - the mutating
# operators (apply / rollback / update / sync). The home plane builds the
# declared homeConfiguration's activationPackage from the flake and runs
# its activate - no home-manager CLI dependency. The system plane wraps
# the platform's rebuild (nixos-rebuild / darwin-rebuild).
#
# The seam law: nix owns the write plane end to end. The driver's tail
# writes the generation RECEIPT — the one event a switch carries. There is
# no daemon to publish to (the resident engine retired with the wire
# protocol): the receipt line lands on stdout and appends to
# `$HOME/.local/state/workstation/switch.log`, and the switch itself is the
# push — every consumer watches a file (the switch log, the theme token
# path the theme module re-points each generation), nothing polls.
#
# Home plane (default) wraps the user's `home-manager` profile; the
# `--system` flag wraps the host's `nixos-rebuild` profile (root runs it).
#
# Baked by the staging module (workstation-home.nix): the flake source
# snapshot THIS generation ships, and the two flake attrs (the leg's
# defaults, verbatim — null means the leg stages no default for that plane).
# Environment overrides (the seams the container E2E and CI use):
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
  flake,
  # the leg's default targets. A null means the leg documented a different
  # mutating seam (the mac leg: --system wraps darwin-rebuild) — the
  # unmarked plane then fails closed with the fix named, never a sentinel
  # attr that looks switchable and lands somewhere broken.
  homeAttr ? null,
  systemAttr ? null,
}:
let
  # The system-plane rebuild tool follows the DRIVER's platform: the
  # darwin-built driver wraps darwin-rebuild (the nix-darwin leg), the
  # Linux-built one wraps nixos-rebuild. Both use the `system` profile, so
  # the generation read after the switch is shared.
  rebuild = if pkgs.stdenv.isDarwin then "darwin-rebuild" else "nixos-rebuild";

  # The receipt: read the switched profile's generation and write the
  # receipt — stdout plus the state tree's switch.log (append; the operator
  # scrollback of every switch this home took). The profile link's tail IS
  # the generation number (home-manager-N-link / system-N-link) — the same
  # source `home-manager generations` reads, never a side-channel counter.
  # A link that doesn't resolve (dangling after a gc, a torn registration)
  # receipts nothing: exit 1, never a fabricated number.
  readAndPublish = ''
    link="$(readlink "$profile" 2>/dev/null || true)"
    if [ -z "$link" ] || [ ! -e "$profile" ]; then
      echo "workstation-switch: no generation link at $profile — nothing receipted" >&2
      exit 1
    fi
    gen="''${link%-link}"
    gen="''${gen##*-}"
    if [ -z "$gen" ] || [ "''${gen//[0-9]/}" != "" ]; then
      echo "workstation-switch: no generation number in $link" >&2
      exit 1
    fi
    if [ "$gen" -ge 2 ]; then
      message="generation $gen applied (rollback available at $((gen - 1)))"
    else
      message="generation $gen applied (no prior generation)"
    fi
    echo "workstation-switch: $message"
    state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/workstation"
    mkdir -p "$state_dir"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $message" >> "$state_dir/switch.log"
  '';

  # The home-plane profile: resolved the way the activation registered it.
  # home-manager's activate derives the profile dir AT SWITCH TIME —
  # $XDG_STATE_HOME/nix/profiles when that dir exists (nix 2.14+ moved the
  # per-user state there), else nix's global per-user profile dir — and
  # registers `home-manager` inside it (nix-env --profile … --set). The
  # driver repeats that exact decision so the receipt reads the same link
  # the switch just wrote: real hosts on determinate nix carry no
  # $XDG_STATE_HOME/nix at all (the registration lands per-user, e.g.
  # /nix/var/nix/profiles/per-user/root/home-manager), while the container
  # E2E stages the XDG dir and stays on the first branch. Fail closed when
  # neither dir exists — that is a host where no switch could have
  # registered anything.
  resolveHomeProfile = ''
    state_home="''${XDG_STATE_HOME:-$HOME/.local/state}"
    user_nix_profiles="''${state_home}/nix/profiles"
    global_profiles="''${NIX_STATE_DIR:-/nix/var/nix}/profiles/per-user/''${USER:-$(id -un 2>/dev/null || true)}"
    if [ -d "$user_nix_profiles" ]; then
      profile="''${user_nix_profiles}/home-manager"
    elif [ -d "$global_profiles" ]; then
      profile="''${global_profiles}/home-manager"
    else
      echo "workstation-switch: no home-manager profile dir — tried $user_nix_profiles and $global_profiles — nothing receipted" >&2
      exit 1
    fi
  '';

  # the fail-closed guards: a plane the leg staged no default for stops at
  # the verb, with the fix named — this is how the mac leg's default-verb
  # `apply` dies instead of switching a fabricated attr
  guards = ''
    need_home() {
      if [ -z "$home_attr" ]; then
        echo "workstation-switch: no default home attr on this leg — set workstation.switch.homeAttr in the host module (or WORKSTATION_SWITCH_HOME_ATTR); this leg's documented mutating seam may be --system" >&2
        exit 2
      fi
    }
    need_system() {
      if [ -z "$system_attr" ]; then
        echo "workstation-switch: no default system attr on this leg — set workstation.switch.systemAttr in the host module (or WORKSTATION_SWITCH_SYSTEM_ATTR)" >&2
        exit 2
      fi
    }
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
  home_attr="''${WORKSTATION_SWITCH_HOME_ATTR:-${if homeAttr == null then "" else homeAttr}}"
  system_attr="''${WORKSTATION_SWITCH_SYSTEM_ATTR:-${if systemAttr == null then "" else systemAttr}}"
  home_activate="''${WORKSTATION_SWITCH_HOME_ACTIVATE:-}"
  ${guards}

  case "$plane:$cmd" in
    home:apply|home:sync)
      need_home
      if [ -n "$home_activate" ]; then
        "$home_activate"
      else
        gen="$(nix build --no-link --print-out-paths "$flake#homeConfigurations.$home_attr.activationPackage" | tail -n 1)"
        "$gen/activate"
      fi
      ${resolveHomeProfile}
      ;;
    home:rollback)
      ${resolveHomeProfile}
      nix-env --profile "$profile" --rollback
      "$profile/activate"
      ;;
    home:update)
      need_home
      nix flake update --flake "$flake"
      gen="$(nix build --no-link --print-out-paths "$flake#homeConfigurations.$home_attr.activationPackage" | tail -n 1)"
      "$gen/activate"
      ;;
    system:apply|system:sync)
      need_system
      ${rebuild} switch --flake "$flake#$system_attr"
      profile=/nix/var/nix/profiles/system
      ;;
    system:rollback)
      ${rebuild} switch --rollback
      profile=/nix/var/nix/profiles/system
      ;;
    system:update)
      need_system
      nix flake update --flake "$flake"
      ${rebuild} switch --flake "$flake#$system_attr"
      profile=/nix/var/nix/profiles/system
      ;;
  esac

  # The receipt closes the run: a broken generation read fails the switch
  # run loudly (exit 1), never silently.
  ${readAndPublish}
''
