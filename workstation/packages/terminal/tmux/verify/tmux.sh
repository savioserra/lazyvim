#!/bin/sh
# tmux package verify — the pinned-checkout contract (read-only).
#
# Asserts the TPM plugin set is engine-provisioned: every git recipe in the
# tmux package manifest (tpm, tmux2k, tmux-yank, tmux-resurrect,
# vim-tmux-navigator) has its checkout at ~/.tmux/plugins/<name> with HEAD
# at the pinned commit — so TPM sources pre-installed checkouts and a fresh
# box never loads a half-installed or un-themed plugin set. nunchux, the
# sixth plugin, is owned and verified by packages/nunchux (verify/nunchux.sh).
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
manifest=$root/packages/terminal/tmux/manifest.json

fail() {
  echo "tmux verify: $1" >&2
  exit 1
}

[ -f "$manifest" ] || fail "tmux package manifest not found at $manifest (set WORKSTATION_ENGINE_REPO)"
command -v git >/dev/null 2>&1 || fail "git not on PATH; cannot verify the pinned checkouts"

# The declared pins: one "target|url|commit" triple per git recipe, in
# manifest order (tpm first — it must exist before the first tmux start).
pins=$(awk '
  /"provider": "git"/ { ingit = 1 }
  ingit && /"url":/ { match($0, /"url": "[^"]*"/); url = substr($0, RSTART + 8, RLENGTH - 9) }
  ingit && /"commit":/ { match($0, /"commit": "[^"]*"/); commit = substr($0, RSTART + 11, RLENGTH - 12) }
  ingit && /"target":/ {
    match($0, /"target": "[^"]*"/)
    target = substr($0, RSTART + 11, RLENGTH - 12)
    print target "|" url "|" commit
    ingit = 0
  }
' "$manifest")
[ -n "$pins" ] || fail "no git recipes in $manifest — the plugin set must stay engine-provisioned"

echo "$pins" | while IFS='|' read -r target url commit; do
  checkout=$home/$target
  [ -d "$checkout" ] || fail "$target checkout missing at $checkout (run: workstation apply)"
  head=$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)
  [ -n "$head" ] || fail "$checkout is not a git checkout (engine-provisioned pinned clone expected)"
  [ "$head" = "$commit" ] || fail "$checkout HEAD $head does not carry the pinned commit $commit ($url)"
  echo "tmux verify: ok — $target at the pinned commit $commit"
done

echo "tmux verify: the engine-provisioned plugin set is at its pins"
