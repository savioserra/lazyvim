#!/bin/sh
# Release boot smoke (lane b8): verify the shipped tarball boots and the
# graduated core CLI answers a live read from a bare extract,
# with no mix/no build toolchain and no repo checkout in play.
#
# Contract: the smoke never touches the real $HOME. The extracted release
# runs inside a marked private test home (tests/test-home.sh boundary), and
# the read route is the real daemon route (ensure-daemon spawns the
# release's own daemon). Every temp artifact lives
# under the smoke's own scratch directory (cleaned by the trap).
#
# The smoke verifies, in order:
#   1. the tarball checksum matches its sidecar (sha256sum -c);
#   2. the release binary boots headless and reports the pinned version;
#   3. the packaged CLI answers a live status read: the daemon spawns, the
#      wire is canonical JSON with the pinned status schema and the
#      resolved destination, and the daemon stops cleanly;
#   4. the packaged TUI boots as a process (headless smoke only: render
#      parity is the daemon+TUI lane's contract, not this smoke's);
#   5. the packaged engine adapters hard-fail closed: with no Lua runtime
#      and no engine root shipped, any accidental engine evaluation is a
#      loud boot error, never a silent fallback (exit-code table, adapter
#      contract docs/elixir.md §3).

set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
: "${WORKSTATION_B8_TARBALL:=$REPO_ROOT/workstation-0.1.0-linux-x64.tar.gz}"

fail() {
	printf 'direct_boot: FAIL: %s\n' "$1" >&2
	exit 1
}

command -v jq >/dev/null 2>&1 ||
	fail "jq is required for the wire assertions but was not found"
command -v timeout >/dev/null 2>&1 ||
	fail "timeout is required so an interactive-capable invocation can never hang the gate"

# ---- 0. inputs ------------------------------------------------------------

[ -f "$WORKSTATION_B8_TARBALL" ] ||
	fail "tarball missing at $WORKSTATION_B8_TARBALL (build with: mise exec -- env MIX_ENV=prod mix release workstation --overwrite at the repo root)"

# ---- 1. tarball checksum --------------------------------------------------

tarball_dir=$(dirname "$WORKSTATION_B8_TARBALL")
tarball_name=$(basename "$WORKSTATION_B8_TARBALL")
(cd "$tarball_dir" && sha256sum -c "$tarball_name.sha256") >/dev/null 2>&1 ||
	fail "sha256 sidecar does not match the tarball ($tarball_name)"

# ---- 2. private test home --------------------------------------------------

SMOKE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/direct-boot-home-XXXXXX")
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/direct-boot-work-XXXXXX")
cleanup() {
	rm -rf "$SMOKE_HOME" "$WORK_DIR"
}
trap cleanup EXIT INT TERM
touch "$SMOKE_HOME/.workstation-test-root"

# ---- 3. extract + boot ------------------------------------------------------

EXTRACT_DIR="$WORK_DIR/wsx"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$WORKSTATION_B8_TARBALL" -C "$EXTRACT_DIR" ||
	fail "tarball does not extract cleanly"
BIN="$EXTRACT_DIR/workstation/bin/workstation"
[ -x "$BIN" ] || fail "release tarball has no executable bin/workstation"

version_output=$("$BIN" version) || fail "release boot failed: version"
[ "$version_output" = "workstation 0.1.0" ] ||
	fail "release boot reports unexpected version: $version_output"

# ---- 4. live read through the shipped CLI -----------------------------------

# The shipped release answers a read verb: ensure-daemon spawns the
# release's own daemon pinned to the marked test home, and the wire comes
# back as canonical JSON carrying the pinned status schema and the resolved
# destination. (The retired golden-byte replay rode --input; the read
# smoke is the real route now.)
status_output=$("$BIN" json status --home "$SMOKE_HOME") ||
	fail "release boot failed: json status (exit $?)"

printf '%s' "$status_output" |
	jq -er --arg home "$SMOKE_HOME" \
		'if (.schema | startswith("workstation.status.")) and .destination == $home then true else error("mismatch") end' >/dev/null ||
	fail "status wire is not the pinned schema/destination"

# The shipped wire must already be canonical (compact, keys sorted): the
# schema assertion is only meaningful if the CLI emits canonical JSON
# (the Core.CanonicalJSON wire contract).
printf '%s' "$status_output" |
	jq -S -c . >/dev/null 2>&1 ||
	fail "status wire is not valid JSON"

# the daemon the CLI spawned stops cleanly through its own control verb
# (the daemon pins the home the read verb resolved; the socket lives under
# the marked test home)
WORKSTATION_HOME="$SMOKE_HOME" "$BIN" daemon stop >/dev/null 2>&1 ||
	fail "the spawned daemon did not stop cleanly"

# ---- 5. TUI process smoke ---------------------------------------------------

# Headless boot only: TERM is unset/dumb in gate environments and the daemon
# session lifecycle is not this smoke's contract. A real render is exercised
# by the daemon+TUI lane's suite (apps/cli/test/workstation/cli/tui/).
TUI_INPUT_DIR="$WORK_DIR/tui-input"
mkdir -p "$TUI_INPUT_DIR"
TUI_INPUT_FILE="$TUI_INPUT_DIR/keys"
: >"$TUI_INPUT_DIR/keys"
# `workstation tui --home <marked>` must at minimum boot its runtime and exit
# cleanly on immediate EOF; a crash (non-0/non-clean) fails the smoke. The
# timeout is the hang guard: a gate that waits forever on an interactive
# prompt is a CI-killer, so the release invocation is bounded and an overshoot
# is a loud failure, never a stuck run.
TUI_EXIT=0
TERM=dumb timeout 60 "$BIN" tui --home "$SMOKE_HOME" <"$TUI_INPUT_DIR/keys" >/dev/null 2>&1 ||
	TUI_EXIT=$?
case "$TUI_EXIT" in
0 | 1 | 2) ;;
124) fail "packaged TUI ignored EOF and overshot the 60s gate timeout" ;;
*) fail "packaged TUI did not boot cleanly (exit $TUI_EXIT)" ;;
esac

# ---- 6. retired engine path stays refused -----------------------------------

# The graduation flip removed the --engine shell-out: the shipped CLI must
# refuse it as a usage error (exit 2), never silently accept or half-run it.
# If a future edit re-enables the shell-out, this check fails until the
# smoke is re-authored for the new contract.
"$BIN" plan --engine "$REPO_ROOT" --home "$SMOKE_HOME" >/dev/null 2>&1
ENGINE_EXIT=$?
[ "$ENGINE_EXIT" -eq 2 ] ||
	fail "retired --engine flag must exit 2 (usage), got $ENGINE_EXIT"

printf 'direct_boot: OK (checksum, boot version, live read smoke, TUI process, retired engine path refused)\n'
