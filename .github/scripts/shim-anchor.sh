#!/bin/sh
# Shim engine-repo anchor gate. The public launcher shim must anchor the
# engine checkout for EVERY verb: a checkout-launched
# release resolves the engine checkout through WORKSTATION_ENGINE_REPO, and
# before the anchor hoist every checkout-launched verb failed closed unless
# the caller preset the variable by hand. Each step runs inside its
# own test-home.sh process boundary (env -i: no ambient
# WORKSTATION_ENGINE_REPO survives) against the shipped release tarball, so
# the anchor can only come from the shim itself.
#
# Contract asserted:
#   1. checkout shim + read verb, no preset env, cwd outside any checkout
#      context -> exit 0 (the shim exported the anchor; the read answers
#      in-process from the baked report — the wire is the pinned schema
#      with the resolved destination). The read leaves NO daemon state
#      behind: the resident engine retired with the wire protocol, so a
#      socket dir under the state tree is a regression, not an
#      implementation detail.
#   2. bare-host copy of the shim (no checkout around it) in a FRESH
#      fixture home -> the same read answers the same way: the release's
#      reads are self-contained (the report rides the release), so a bare
#      host is a WORKING host, not a refused one. The env boundary holds —
#      WORKSTATION_ENGINE_REPO never crosses the fixture.
set -eu
repo_root=$(CDPATH='' cd -P "$(dirname "$0")/../.." && pwd -P)
tarball=$repo_root/workstation-0.1.0-linux-x64.tar.gz
[ -f "$tarball" ] ||
	{ echo 'shim-anchor: release tarball missing; build it first (docs/elixir.md §distribution)' >&2; exit 1; }

# 1. Checkout shim, non-bootstrap verb, no preset env: must succeed, and
#    the read must leave no daemon state behind.
# shellcheck disable=SC2016
sh "$repo_root/.github/scripts/test-home.sh" sh -eu -c '
	fail() { echo "shim-anchor: FAIL: $*" >&2; exit 1; }
	repo=$1
	tarball=$2
	[ "${WORKSTATION_ENGINE_REPO:-}" = "" ] ||
		fail "WORKSTATION_ENGINE_REPO must not cross the fixture boundary"
	mkdir -p "$HOME/.local/opt"
	tar -xzf "$tarball" -C "$HOME/.local/opt"
	[ -x "$HOME/.local/opt/workstation/bin/workstation" ] ||
		fail "staged release lacks bin/workstation"
	cd "$HOME"
	status_output=$("$repo/workstation/bin/workstation" json status --home "$HOME" 2>"$HOME/shim-status.err") ||
		{ cat "$HOME/shim-status.err" >&2; fail "checkout shim read failed (anchor not exported?)"; }
	printf "%s" "$status_output" |
		jq -er --arg home "$HOME" \
			"if (.schema | startswith(\"workstation.status.\")) and .destination == \$home then true else error(\"mismatch\") end" >/dev/null ||
		fail "the read wire is not the pinned schema/destination"
	[ ! -e "$HOME/.local/state/workstation/daemon" ] ||
		fail "the read left daemon state behind — the resident engine regressed"
' sh "$repo_root" "$tarball"

# 2. Bare-host shim copy in a fresh fixture home: no checkout around it,
#    the same read answers from the release's own baked report.
# shellcheck disable=SC2016
sh "$repo_root/.github/scripts/test-home.sh" sh -eu -c '
	fail() { echo "shim-anchor: FAIL: $*" >&2; exit 1; }
	repo=$1
	tarball=$2
	[ "${WORKSTATION_ENGINE_REPO:-}" = "" ] ||
		fail "WORKSTATION_ENGINE_REPO must not cross the fixture boundary"
	mkdir -p "$HOME/.local/opt"
	tar -xzf "$tarball" -C "$HOME/.local/opt"
	bare=$HOME/.local/opt/bare-host/bin
	mkdir -p "$bare"
	cp "$repo/workstation/bin/workstation" "$bare/workstation"
	# Guard, not cleanup: a home with prior engine state is not a bare
	# host and would make the fresh-home assertion vacuous.
	[ ! -e "$HOME/.local/state/workstation" ] ||
		fail "fixture home already carries engine state; bare-host assertion would be vacuous"
	cd "$HOME"
	status_output=$("$bare/workstation" json status --home "$HOME" 2>"$HOME/bare-status.err") ||
		{ cat "$HOME/bare-status.err" >&2; fail "bare-host read failed (the release reads are self-contained)"; }
	printf "%s" "$status_output" |
		jq -er ".schema" >/dev/null ||
		fail "the bare-host wire is not the pinned schema"
	[ ! -e "$HOME/.local/state/workstation/daemon" ] ||
		fail "the bare-host read left daemon state behind"
' sh "$repo_root" "$tarball"

echo 'shim-anchor: OK (checkout shim and bare-host copy both answer reads in-process; no daemon state, no env crossing)'
