#!/bin/sh
# nunchux package verify — the pinned-checkout contract (read-only).
#
# Asserts the substrate-provisioned plugin checkout upstream's nunchux.tmux
# relies on: ~/.tmux/plugins/nunchux is a git checkout at the pinned commit
# (the terminal module's declared pin, deployed as
# ~/.tmux/plugins.pins.json), bin/nunchux is the executable repo build
# recorded by the pin's repo_linux_amd64_sha256, and bin/.platform carries
# the platform marker ensure_binary compares — so plugin load runs the
# commit-pinned binary and never fetches releases/latest unchecksummed.
# Never executes the binary.
#
# The engine never runs this script; it is the host lane's assertion surface
# (docs/capabilities.md "Package payload rule"). Exits nonzero with a message
# on the first failed assertion.
set -eu

home=${WORKSTATION_VERIFY_HOME:-$HOME}
# the deployed pin manifest: the terminal module's declared pins, deployed
# beside the checkouts at activation
manifest=$home/.tmux/plugins.pins.json
checkout=$home/.tmux/plugins/nunchux
bin=$checkout/bin/nunchux
platform_file=$checkout/bin/.platform

fail() {
  echo "nunchux verify: $1" >&2
  exit 1
}

[ -f "$manifest" ] || fail "deployed pin manifest not found at $manifest (run: workstation apply)"
command -v git >/dev/null 2>&1 || fail "git not on PATH; cannot verify the pinned checkout"

row=$(grep -o '"nunchux":{[^}]*}' "$manifest" || true)
[ -n "$row" ] || fail "no nunchux pin in $manifest"
pin_commit=$(printf '%s' "$row" | sed -n 's/.*"rev":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p')
pin_sha=$(printf '%s' "$row" | sed -n 's/.*"repo_linux_amd64_sha256":[[:space:]]*"\([0-9a-f]\{64\}\)".*/\1/p')
[ -n "$pin_commit" ] || fail "the nunchux pin carries no rev"
[ -n "$pin_sha" ] || fail "the nunchux pin carries no repo_linux_amd64_sha256"

[ -d "$checkout" ] || fail "plugin checkout missing at $checkout (run: workstation apply)"
head=$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)
[ -n "$head" ] || fail "$checkout is not a git checkout (engine-provisioned pinned clone expected)"
[ "$head" = "$pin_commit" ] || fail "checkout HEAD $head does not carry the pinned commit $pin_commit"

[ -f "$bin" ] || fail "checkout binary missing at $bin"
[ -x "$bin" ] || fail "binary at $bin is not executable"

actual=$(sha256sum "$bin" | awk '{print $1}')
[ "$actual" = "$pin_sha" ] || fail "binary sha256 $actual does not match the pinned repo build $pin_sha (commit $pin_commit)"

[ -f "$platform_file" ] || fail "platform marker missing at $platform_file (ensure_binary would re-download)"
marker=$(cat "$platform_file")
[ "$marker" = "linux-amd64" ] || fail "platform marker '$marker' is not linux-amd64 (ensure_binary would re-download)"

echo "nunchux verify: ok — $checkout is at the pinned commit $pin_commit; ensure_binary will not fetch"
