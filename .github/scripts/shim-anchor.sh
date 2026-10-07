#!/bin/sh
# Shim engine-repo anchor gate. The public launcher shim must anchor the
# engine checkout for EVERY verb, not only bootstrap: a checkout-launched
# release resolves the engine checkout (package assets, update steps)
# through WORKSTATION_ENGINE_REPO, and before the anchor hoist every
# non-bootstrap verb failed closed (exit 4, "no engine checkout found")
# unless the caller preset the variable by hand. Each step runs inside its
# own test-home.sh process boundary (env -i: no ambient
# WORKSTATION_ENGINE_REPO survives) against the shipped release tarball, so
# the anchor can only come from the shim itself.
#
# Contract asserted:
#   1. checkout shim + read verb, no preset env, cwd outside any checkout
#      context -> exit 0 (the shim exported the anchor); the read spawns a
#      resident daemon (ensure-daemon), and that daemon INHERITS the
#      exported anchor through the spawn environment — so the step ends by
#      stopping it (the manual stop confirms the beam is gone). A surviving
#      anchored daemon would serve any later run for the same home through
#      the socket and make a bare-host check vacuous (the 2026-10-07 leak:
#      step 2 of this gate rode step 1's daemon and "passed" without ever
#      exercising the bare host).
#   2. bare-host copy of the shim (no checkout around it) in a FRESH
#      fixture home -> exit 4 with the fail-closed engine-checkout error
#      (a bare host keeps today's no-export contract, never a guessed
#      anchor). The guard proves the home carries no daemon state before
#      the shim runs, so the failure is the release's own fail-closed
#      detection and not a socket answer from a leaked daemon.
set -eu
repo_root=$(CDPATH='' cd -P "$(dirname "$0")/../.." && pwd -P)
tarball=$repo_root/elixir/workstation-0.1.0-linux-x64.tar.gz
[ -f "$tarball" ] ||
	{ echo 'shim-anchor: release tarball missing; build it first (docs/elixir.md §distribution)' >&2; exit 1; }

# 1. Checkout shim, non-bootstrap verb, no preset env: must succeed — and
#    the daemon it spawned must not outlive the step.
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
	"$repo/workstation/bin/workstation" diff --home "$HOME" >/dev/null 2>"$HOME/shim-diff.err" ||
		{ cat "$HOME/shim-diff.err" >&2; fail "checkout shim diff failed (anchor not exported?)"; }
	"$repo/workstation/bin/workstation" daemon stop >/dev/null 2>"$HOME/daemon-stop.err" ||
		{ cat "$HOME/daemon-stop.err" >&2; fail "the daemon spawned by the anchored read outlived the stop"; }
' sh "$repo_root" "$tarball"

# 2. Bare-host shim copy in a fresh fixture home: no anchor around it, so
#    nothing may be exported and the release must fail closed with its own
#    error.
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
	# Guard, not cleanup: a home with daemon state is not a bare host, and
	# a daemon serving it could answer through the socket and void the
	# assertion below (the anchor would arrive through the spawn
	# environment of an earlier step, never through this shim).
	[ ! -e "$HOME/.local/state/workstation" ] ||
		fail "fixture home already carries daemon state; bare-host assertion would be vacuous"
	if "$bare/workstation" diff --home "$HOME" >/dev/null 2>"$HOME/bare-diff.err"; then
		fail "bare-host shim unexpectedly reached an engine (anchor export or leaked daemon)"
	fi
	grep -q "no engine checkout found" "$HOME/bare-diff.err" ||
		fail "bare-host failure is not the fail-closed engine-checkout error"
	# The refused read still spawned a resident daemon (ensure-daemon
	# spawns before the engine check fires daemon-side); retire it so the
	# gate never leaks a beam into the fixture tree. The control path
	# needs no anchor — the manual stop proves that here too.
	"$bare/workstation" daemon stop >/dev/null 2>"$HOME/daemon-stop.err" ||
		{ cat "$HOME/daemon-stop.err" >&2; fail "the bare-host run left a daemon behind"; }
' sh "$repo_root" "$tarball"

echo 'shim-anchor: OK (checkout shim anchors non-bootstrap verbs and stops its daemon; bare host stays unanchored)'
