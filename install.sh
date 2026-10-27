#!/bin/sh
# The workstation one-line install:
#
#   curl -fsSL https://raw.githubusercontent.com/savioserra/lazyvim/main/install.sh | sh
#
# The guarded form (read what runs, then execute) is the recommended one:
#
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/savioserra/lazyvim/main/install.sh)"
#
# What it does: ensures nix (the one hard prerequisite), clones this repo
# to $WORKSTATION_CHECKOUT (default: ~/lazyvim), and runs `workstation
# init` — the identity capture (whiptail dialogs prefilled with the
# detected values; no TTY falls back to the detected values) and the first
# switch. Every later update is `workstation apply`.
#
# Environment:
#   WORKSTATION_CHECKOUT   where the clone lands (default ~/lazyvim)
#   WORKSTATION_REPO       the clone URL (default: this repository)
#   WORKSTATION_NO_APPLY=1 capture the identity, skip the first switch
set -eu

log() { printf 'install: %s\n' "$1"; }

# --- the one prerequisite: nix --------------------------------------------
if ! command -v nix >/dev/null 2>&1; then
	log 'nix not found — installing (Determinate Nix)'
	case "$(uname -s)" in
	Darwin) installer_target='' ;;
	Linux) installer_target='linux' ;;
	*) printf 'install: unsupported platform %s\n' "$(uname -s)" >&2; exit 1 ;;
	esac
	curl --proto '=https' --tlsv1.2 -fsSL https://install.determinate.systems/nix |
		sh -s -- install ${installer_target:+"$installer_target"} --no-confirm
fi
for profile in /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh \
	/nix/etc/profile.d/nix-daemon.sh; do
	[ -f "$profile" ] && . "$profile" && break
done
command -v nix >/dev/null 2>&1 ||
	{ printf 'install: nix is installed but not on PATH — open a new shell and re-run\n' >&2; exit 1; }
export NIX_CONFIG="extra-experimental-features = nix-command flakes"

# --- the clone -------------------------------------------------------------
repo=${WORKSTATION_REPO:-https://github.com/savioserra/lazyvim.git}
checkout=${WORKSTATION_CHECKOUT:-"$HOME/lazyvim"}
if [ -d "$checkout/.git" ]; then
	log "checkout exists at $checkout — updating"
	git -C "$checkout" pull --ff-only
else
	log "cloning into $checkout"
	git clone "$repo" "$checkout"
fi
[ -f "$checkout/bin/workstation" ] ||
	{ printf 'install: %s is not a workstation checkout (no bin/workstation)\n' "$checkout" >&2; exit 1; }

# --- identity capture + the first switch ------------------------------------
log 'capturing this machine'"'"'s identity and applying'
cd "$checkout"
exec ./bin/workstation init
