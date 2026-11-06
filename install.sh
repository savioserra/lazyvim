#!/bin/sh
# The workstation one-line install:
#
#   curl -fsSL https://raw.githubusercontent.com/savioserra/workstation/main/install.sh | sh
#
# The guarded form (read what runs, then execute) is the recommended one:
#
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/savioserra/workstation/main/install.sh)"
#
# Ensures nix, clones this repo to $WORKSTATION_CHECKOUT (default
# ~/workstation) and runs `workstation init`: the machine capture into
# hosts/local/machine.json, the fleet choice and the first switch. Every later
# update is `workstation apply`.
#
# Environment:
#   WORKSTATION_CHECKOUT   where the clone lands (default ~/workstation; an
#                          existing ~/lazyvim checkout keeps its path)
#   WORKSTATION_REPO       the clone URL (default: this repository)
#   WORKSTATION_NO_APPLY=1 capture the machine, skip the first switch
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
	# shellcheck disable=SC1090  # the profile path is fixed above, not a variable
	[ -f "$profile" ] && . "$profile" && break
done
command -v nix >/dev/null 2>&1 ||
	{ printf 'install: nix is installed but not on PATH — open a new shell and re-run\n' >&2; exit 1; }
export NIX_CONFIG="extra-experimental-features = nix-command flakes"

# --- the clone -------------------------------------------------------------
repo=${WORKSTATION_REPO:-https://github.com/savioserra/workstation.git}
checkout=${WORKSTATION_CHECKOUT:-"$HOME/workstation"}
if [ ! -d "$checkout/.git" ] && [ -d "$HOME/lazyvim/.git" ]; then
	checkout=$HOME/lazyvim
fi
if [ -d "$checkout/.git" ]; then
	log "checkout exists at $checkout — updating"
	git -C "$checkout" pull --ff-only
else
	log "cloning into $checkout"
	git clone "$repo" "$checkout"
fi
[ -f "$checkout/bin/workstation" ] ||
	{ printf 'install: %s is not a workstation checkout (no bin/workstation)\n' "$checkout" >&2; exit 1; }

# --- the machine capture, the fleet choice and the first switch ------------
cd "$checkout"
# `curl ... | sh` holds stdin: the dialogs read /dev/tty; whiptail comes
# from the checkout's nixpkgs until the first switch ships it
tty_in=''
if [ -t 0 ]; then
	tty_in=stdin
elif (: </dev/tty) 2>/dev/null; then
	tty_in=/dev/tty
fi
if [ -n "$tty_in" ] && ! command -v whiptail >/dev/null 2>&1; then
	if newt=$(nix build --no-link --print-out-paths --inputs-from . nixpkgs#newt 2>/dev/null); then
		PATH=$newt/bin:$PATH
		export PATH
	else
		log 'whiptail unavailable — init captures the detected values'
	fi
fi
log 'capturing this machine and applying'
if [ "$tty_in" = /dev/tty ]; then
	exec ./bin/workstation init </dev/tty
fi
exec ./bin/workstation init
