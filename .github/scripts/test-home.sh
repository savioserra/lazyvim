#!/bin/sh
# Test-only process boundary. PATH is the caller's prerequisite/fixture PATH;
# installed executables must be passed as absolute paths before HOME changes.
set -eu
[ "$#" -gt 0 ] || { echo 'usage: test-home.sh <command> [arguments...]' >&2; exit 2; }
umask 077
# Do not derive fixture paths from caller HOME/TMP/XDG or delete caller input.
root=$(mktemp -d /tmp/workstation-test.XXXXXX)
printf 'test-home: %s\n' "$root" >&2
mkdir "$root/home" "$root/tmp" "$root/config" "$root/data" "$root/state" "$root/cache" "$root/run"
# Fixture archive defaults are 0644/0755, independent of caller umask. The
# enclosing root and writable directories remain private (0700).
umask 022
# Retain this owned root on success/failure for inspection; no cleanup trap can
# erase caller state. No auth, agent, session or tool configuration is inherited.
exec env -i PATH="$PATH" HOME="$root/home" WORKSTATION_HOME="$root/home" \
	TMPDIR="$root/tmp" TMP="$root/tmp" TEMP="$root/tmp" \
	XDG_CONFIG_HOME="$root/config" XDG_DATA_HOME="$root/data" \
	XDG_STATE_HOME="$root/state" XDG_CACHE_HOME="$root/cache" XDG_RUNTIME_DIR="$root/run" \
	XDG_CONFIG_DIRS="$root/config" XDG_DATA_DIRS="$root/data" WORKSTATION_CACHE="$root/cache/workstation" \
	GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_GLOBAL=/dev/null \
	"$@"
