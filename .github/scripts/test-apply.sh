#!/bin/sh
# Real integration harness. Never source login profiles or accept an existing home.
set -eu
PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH
fail() { echo "test-apply: $*" >&2; exit 1; }
[ "$#" -eq 1 ] || fail 'usage: test-apply.sh <new absolute scratch directory>'
case "$1" in /*) ;; *) fail 'scratch path must be absolute' ;; esac
case "$1" in */|*/.|*/..) fail 'scratch path must name a new directory' ;; esac
repo_root=$(CDPATH='' cd -P "$(dirname "$0")/../.." && pwd -P)
parent=$(CDPATH='' cd -P "$(dirname "$1")" && pwd -P)
scratch_home=$parent/$(basename "$1")
real_home=$(CDPATH='' cd -P "$HOME" && pwd -P)
for protected in / "$real_home" "$repo_root"; do
	[ "$scratch_home" != "$protected" ] || fail 'protected destination'
	case "$protected/" in "$scratch_home/"*) fail 'destination contains home or source' ;; esac
done
case "$scratch_home/" in "$real_home/"*|"$repo_root/"*) fail 'destination is inside home or source' ;; esac
if [ -e "$scratch_home" ] || [ -L "$scratch_home" ]; then
	fail 'destination already exists; use a new scratch path'
fi
umask 077
mkdir "$scratch_home" # Atomic ownership claim; never delete caller input, even on failure.
# A fixed prerequisite PATH is intentional: no ambient managed Node/Neovim,
# agents, credentials, session sockets, Git config or provider settings survive.
# Homebrew's standard arm64 prefix supplies CI/user-owned Bash and tmux on macOS.
# The child expands variables only after env -i has replaced the environment.
# shellcheck disable=SC2016
exec env -i HOME="$scratch_home" WORKSTATION_HOME="$scratch_home" \
	PATH="$PATH" \
	XDG_CONFIG_HOME="$scratch_home/.config" XDG_DATA_HOME="$scratch_home/.local/share" \
	XDG_STATE_HOME="$scratch_home/.local/state" XDG_CACHE_HOME="$scratch_home/.cache" \
	XDG_RUNTIME_DIR="$scratch_home/.local/state/workstation/run" \
	TMPDIR="$scratch_home/.local/state/workstation/run/tmp" \
	WORKSTATION_CACHE="$scratch_home/.cache/workstation" \
	GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_GLOBAL=/dev/null \
	sh -eu -c '
		repo_root=$1
		mkdir -p "$TMPDIR"
		cd "$repo_root"
		"$repo_root/workstation/bin/workstation" bootstrap
		launcher=$HOME/.local/bin/workstation
		"$launcher" apply
		"$launcher" sync
		sh "$repo_root/.github/scripts/check.sh"
		"$launcher" verify
	' sh "$repo_root"
