# The write plane: workstation-switch apply|rollback|update|sync, with a
# receipt line in ~/.local/state/workstation/switch.log.
{
  pkgs,
  flake,
  homeAttr ? null,
  systemAttr ? null,
}:
let
  rebuild = if pkgs.stdenv.hostPlatform.isDarwin then "darwin-rebuild" else "nixos-rebuild";

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
