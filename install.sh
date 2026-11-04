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
# init` — the identity capture and the fleet choice (whiptail dialogs on
# the terminal, prefilled with the detected values; no TTY falls back to
# the detected values and a fleet member) and the first switch. Every
# later update is `workstation apply`.
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
	# shellcheck disable=SC1090  # the profile path is fixed above, not a variable
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
	# the machine files (identity, selections, peers) are uncommitted by
	# law; stash them across the pull, init re-merges them after. Only the
	# files the checkout carries: a pathspec the old tree lacks fails the
	# whole stash
	set --
	for f in hosts/identity.nix hosts/selections.nix hosts/peers.nix; do
		if [ -e "$checkout/$f" ]; then set -- "$@" "$f"; fi
	done
	git -C "$checkout" stash push -q -- "$@" 2>/dev/null || true
	git -C "$checkout" pull --ff-only
	git -C "$checkout" stash pop -q 2>/dev/null || true
else
	log "cloning into $checkout"
	git clone "$repo" "$checkout"
fi
[ -f "$checkout/bin/workstation" ] ||
	{ printf 'install: %s is not a workstation checkout (no bin/workstation)\n' "$checkout" >&2; exit 1; }

# --- identity capture, the fleet choice + the first switch -----------------
cd "$checkout"
# the dialogs run on the terminal: `curl ... | sh` hands the script on
# stdin, so init reads /dev/tty; whiptail comes from the checkout's pinned
# nixpkgs until the first switch ships it
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
log 'capturing this machine'"'"'s identity and applying'
if [ "$tty_in" = /dev/tty ]; then
	exec ./bin/workstation init </dev/tty
fi
exec ./bin/workstation init
