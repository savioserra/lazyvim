#!/bin/sh
# nunchux package verify — the pinned pre-seed contract (read-only).
#
# Asserts the download-contract pre-seed upstream's nunchux.tmux ensure_binary
# relies on: ~/.tmux/plugins/nunchux/bin/nunchux is the pinned 3.1.3
# linux-x86_64 release artifact (sha256 == workstation/versions.json) and
# bin/.platform carries the platform marker ensure_binary compares, so plugin
# load never fetches releases/latest unchecksummed. Never executes the binary.
#
# The engine never runs this script; it is the host lane's assertion surface
# (docs/capabilities.md "Package payload rule"). Exits nonzero with a message
# on the first failed assertion.
set -eu

home=${WORKSTATION_VERIFY_HOME:-$HOME}
here=$(cd "$(dirname "$0")" && pwd)
root=${WORKSTATION_ENGINE_REPO:-$here/../../../..}
manifest=$root/versions.json
bin=$home/.tmux/plugins/nunchux/bin/nunchux
platform_file=$home/.tmux/plugins/nunchux/bin/.platform

fail() {
  echo "nunchux verify: $1" >&2
  exit 1
}

[ -f "$manifest" ] || fail "versions manifest not found at $manifest (set WORKSTATION_ENGINE_REPO)"

pin_version=$(sed -n 's/.*"nunchux":[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -n 1)
pin_sha=$(sed -n 's/.*"nunchux_linux_x86_64_sha256":[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -n 1)
[ -n "$pin_version" ] || fail "nunchux version pin missing from $manifest"
[ -n "$pin_sha" ] || fail "nunchux_linux_x86_64_sha256 pin missing from $manifest"

[ -f "$bin" ] || fail "pre-seeded binary missing at $bin (run: workstation apply)"
[ -x "$bin" ] || fail "binary at $bin is not executable"

actual=$(sha256sum "$bin" | awk '{print $1}')
[ "$actual" = "$pin_sha" ] || fail "binary sha256 $actual does not match the pinned $pin_sha (version $pin_version)"

[ -f "$platform_file" ] || fail "platform marker missing at $platform_file (ensure_binary would re-download)"
marker=$(cat "$platform_file")
[ "$marker" = "linux-amd64" ] || fail "platform marker '$marker' is not linux-amd64 (ensure_binary would re-download)"

echo "nunchux verify: ok — $bin matches the pinned $pin_version linux-x86_64 artifact; ensure_binary will not fetch"
