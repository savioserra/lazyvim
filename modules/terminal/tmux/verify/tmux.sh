#!/bin/sh
# tmux package verify — the pinned-checkout contract (read-only).
#
# Asserts the TPM plugin set is engine-provisioned: every checkout pin the
# terminal module declares (modules/terminal/terminal.nix, deployed as the
# pin manifest ~/.tmux/plugins.pins.json — the deployed pin, never a repo
# file) has its checkout at ~/.tmux/plugins/<name> with HEAD at the pinned
# commit — so TPM sources pre-installed checkouts and a fresh box never
# loads a half-installed or un-themed plugin set. nunchux, the sixth
# plugin, is owned and verified by the terminal domain's nunchux verify
# (verify/nunchux.sh); hermes-agent's git pin is the activation ensure's,
# never a store checkout.
#
# The engine never runs this script; it is the host lane's assertion surface
# (docs/capabilities.md "Package payload rule"). Exits nonzero with a message
# on the first failed assertion.
set -eu

home=${WORKSTATION_VERIFY_HOME:-$HOME}
# the deployed pin manifest: the terminal module's declared pins, deployed
# beside the checkouts at activation
manifest=$home/.tmux/plugins.pins.json

fail() {
  echo "tmux verify: $1" >&2
  exit 1
}

[ -f "$manifest" ] || fail "deployed pin manifest not found at $manifest (run: workstation apply)"
command -v git >/dev/null 2>&1 || fail "git not on PATH; cannot verify the pinned checkouts"

# The plugin set, tpm first (it must exist before the first tmux start).
plugins="tpm tmux2k tmux-yank tmux-resurrect vim-tmux-navigator"

for name in $plugins; do
  row=$(grep -o "\"$name\":{[^}]*}" "$manifest" || true)
  [ -n "$row" ] || fail "no $name pin in $manifest — the plugin set must stay engine-provisioned"
  commit=$(printf '%s' "$row" | sed -n 's/.*"rev":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p')
  [ -n "$commit" ] || fail "the $name pin carries no rev — the manifest must name the pinned commit"
  target=".tmux/plugins/$name"
  checkout=$home/$target
  [ -d "$checkout" ] || fail "$target checkout missing at $checkout (run: workstation apply)"
  head=$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)
  [ -n "$head" ] || fail "$checkout is not a git checkout (engine-provisioned pinned clone expected)"
  [ "$head" = "$commit" ] || fail "$checkout HEAD $head does not carry the pinned commit $commit"
  echo "tmux verify: ok — $target at the pinned commit $commit"
done

echo "tmux verify: the engine-provisioned plugin set is at its pins"
