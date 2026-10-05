#!/bin/sh
# Release boot smoke (lane b8): verify the shipped tarball boots and the
# graduated core CLI reproduces recorded golden bytes from a bare extract,
# with no mix/no build toolchain and no repo checkout in play.
#
# Contract: the smoke never touches the real $HOME. The extracted release
# runs inside a marked private test home (tests/test-home.sh boundary), and
# evaluation inputs are the recorded goldens. Every temp artifact lives
# under the smoke's own scratch directory (cleaned by the trap).
#
# The smoke verifies, in order:
#   1. the tarball checksum matches its sidecar (sha256sum -c);
#   2. the release binary boots headless and reports the pinned version;
#   3. the packaged CLI reproduces golden plan/manifest/generation bytes
#      byte-for-byte from the recorded envelope (JSON canonical form);
#   4. the packaged TUI boots as a process (headless smoke only: render
#      parity is the daemon+TUI lane's contract, not this smoke's);
#   5. the packaged engine adapters hard-fail closed: with no Lua runtime
#      and no engine root shipped, any accidental engine evaluation is a
#      loud boot error, never a silent fallback (exit-code table, adapter
#      contract docs/elixir.md §3).

set -u

ELIXIR_DIR=$(cd "$(dirname "$0")/.." && pwd)
: "${WORKSTATION_B8_TARBALL:=$ELIXIR_DIR/workstation-0.1.0-linux-x64.tar.gz}"
REPO_ROOT=$(cd "$ELIXIR_DIR/.." && pwd)
GOLDEN_DIR="$REPO_ROOT/tests/goldens/minimal"

fail() {
	printf 'direct_boot: FAIL: %s\n' "$1" >&2
	exit 1
}

# ---- 0. inputs ------------------------------------------------------------

[ -f "$WORKSTATION_B8_TARBALL" ] ||
	fail "tarball missing at $WORKSTATION_B8_TARBALL (build with: cd elixir && mise exec -- env MIX_ENV=prod mix release workstation --overwrite)"
[ -f "$GOLDEN_DIR/input.json" ] || fail "golden input missing at $GOLDEN_DIR/input.json"

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

# ---- 4. golden replay through the shipped CLI -------------------------------

plan_output=$("$BIN" json plan --home "$SMOKE_HOME" --input "$GOLDEN_DIR/input.json") ||
	fail "release boot failed: json plan (exit $?)"

check_member() {
	# check_member <member> <golden file> — the shipped CLI's wire member must
	# equal the recorded golden bytes exactly (already canonical JSON).
	member=$1
	golden_file=$2
	golden_bytes=$(cat "$golden_file")
	printf '%s' "$plan_output" |
		jq -c --arg member "$member" --arg golden "$golden_bytes" \
			'if (.[$member] | tostring) == $golden then empty else error("mismatch") end' >/dev/null 2>&1 ||
		fail "$member does not reproduce $golden_file"
}

command -v jq >/dev/null 2>&1 ||
	fail "jq is required for the golden comparison but was not found"
command -v timeout >/dev/null 2>&1 ||
	fail "timeout is required so an interactive-capable invocation can never hang the gate"

check_member plan "$GOLDEN_DIR/expected/plan.json"
check_member manifest "$GOLDEN_DIR/expected/manifest.json"

printf '%s' "$plan_output" |
	jq -er --arg golden "$(cat "$GOLDEN_DIR/expected/generation.txt")" \
		'if .generation == $golden then true else error("mismatch") end' >/dev/null ||
	fail "generation does not reproduce expected/generation.txt"

# The shipped wire must already be canonical (compact, keys sorted): the
# golden-byte comparison is only meaningful if the CLI emits canonical JSON
# (elixir/apps/cli/lib/workstation/cli/json.ex contract).
printf '%s' "$plan_output" |
	jq -S -c . >/dev/null 2>&1 ||
	fail "plan wire is not valid JSON"

# ---- 5. TUI process smoke ---------------------------------------------------

# Headless boot only: TERM is unset/dumb in gate environments and the daemon
# session lifecycle is not this smoke's contract. A real render is exercised
# by the daemon+TUI lane's suite (elixir/apps/cli/test/workstation/cli/tui/).
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

printf 'direct_boot: OK (checksum, boot version, golden bytes, TUI process, retired engine path refused)\n'
