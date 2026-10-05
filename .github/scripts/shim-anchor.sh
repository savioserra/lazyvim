#!/bin/sh
# Shim engine-repo anchor gate. The public launcher shim must anchor the
# engine checkout for EVERY verb, not only bootstrap: a checkout-launched
# release resolves the engine checkout (package assets, update steps)
# through WORKSTATION_ENGINE_REPO, and before the anchor hoist every
# non-bootstrap verb failed closed (exit 4, "no engine checkout found")
# unless the caller preset the variable by hand. The check runs inside the
# test-home.sh process boundary (env -i: no ambient WORKSTATION_ENGINE_REPO
# survives) against the shipped release tarball, so the anchor can only
# come from the shim itself.
#
# Contract asserted:
#   1. checkout shim + read verb, no preset env, cwd outside any checkout
#      context -> exit 0 (the shim exported the anchor);
#   2. bare-host copy of the shim (no checkout around it) + read verb ->
#      exit 4 with the fail-closed engine-checkout error (a bare host keeps
#      today's no-export contract, never a guessed anchor).
set -eu
repo_root=$(CDPATH='' cd -P "$(dirname "$0")/../.." && pwd -P)
tarball=$repo_root/elixir/workstation-0.1.0-linux-x64.tar.gz
[ -f "$tarball" ] ||
	{ echo 'shim-anchor: release tarball missing; build it first (docs/elixir.md §distribution)' >&2; exit 1; }

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
	# 1. Checkout shim, non-bootstrap verb, no preset env: must succeed.
	cd "$HOME"
	"$repo/workstation/bin/workstation" diff --home "$HOME" >/dev/null 2>"$HOME/shim-diff.err" ||
		{ cat "$HOME/shim-diff.err" >&2; fail "checkout shim diff failed (anchor not exported?)"; }
	# 2. Bare-host shim copy: no anchor around it, so nothing may be
	#    exported and the release must fail closed with its own error.
	bare=$HOME/.local/opt/bare-host/bin
	mkdir -p "$bare"
	cp "$repo/workstation/bin/workstation" "$bare/workstation"
	if "$bare/workstation" diff --home "$HOME" >/dev/null 2>"$HOME/bare-diff.err"; then
		fail "bare-host shim unexpectedly exported an engine anchor"
	fi
	grep -q "no engine checkout found" "$HOME/bare-diff.err" ||
		fail "bare-host failure is not the fail-closed engine-checkout error"
' sh "$repo_root" "$tarball"

echo 'shim-anchor: OK (checkout shim anchors non-bootstrap verbs; bare host stays unanchored)'
