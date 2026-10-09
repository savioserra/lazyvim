#!/bin/sh
# nunchux package verify — the pinned-checkout contract (read-only).
#
# Asserts the engine-provisioned plugin checkout upstream's nunchux.tmux
# relies on: ~/.tmux/plugins/nunchux is a git checkout at the pinned commit
# (workstation/versions.json nunchux_git_commit), bin/nunchux is the
# executable repo build recorded by nunchux_repo_linux_amd64_sha256, and
# bin/.platform carries the platform marker ensure_binary compares — so
# plugin load runs the commit-pinned binary and never fetches
# releases/latest unchecksummed. Never executes the binary.
#
# The engine never runs this script; it is the host lane's assertion surface
# (docs/capabilities.md "Package payload rule"). Exits nonzero with a message
# on the first failed assertion.
set -eu

home=${WORKSTATION_VERIFY_HOME:-$HOME}
here=$(cd "$(dirname "$0")" && pwd)
root=${WORKSTATION_ENGINE_REPO:-$here/../../../..}
# WORKSTATION_ENGINE_REPO is the repo anchor (itself or its workstation child).
[ -f "$root/versions.json" ] || root=$root/workstation
manifest=$root/versions.json
checkout=$home/.tmux/plugins/nunchux
bin=$checkout/bin/nunchux
platform_file=$checkout/bin/.platform

fail() {
  echo "nunchux verify: $1" >&2
  exit 1
}

[ -f "$manifest" ] || fail "versions manifest not found at $manifest (set WORKSTATION_ENGINE_REPO)"
command -v git >/dev/null 2>&1 || fail "git not on PATH; cannot verify the pinned checkout"

pin_commit=$(sed -n 's/.*"nunchux_git_commit":[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -n 1)
pin_sha=$(sed -n 's/.*"nunchux_repo_linux_amd64_sha256":[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -n 1)
[ -n "$pin_commit" ] || fail "nunchux_git_commit pin missing from $manifest"
[ -n "$pin_sha" ] || fail "nunchux_repo_linux_amd64_sha256 pin missing from $manifest"

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
