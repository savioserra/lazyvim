#!/bin/sh
# agent package verify — the hermes pinned-checkout contract (read-only).
#
# Asserts the engine-provisioned Hermes Agent checkout the pinned git recipe
# owns: ~/.hermes/hermes-agent is a git checkout at the pinned commit
# (workstation/versions.json hermes_agent_git_commit), the in-checkout
# launcher (~/.hermes/hermes-agent/.hermes/bin/hermes) is an executable that
# reports its version with exit 0, and the managed skills deploy at their
# declared targets (~/.hermes/skills/secrets/SKILL.md).
#
# The engine never runs this script; it is the host lane's assertion surface
# (docs/capabilities.md "Package payload rule"). Exits nonzero with a message
# on the first failed assertion.
set -eu

home=${WORKSTATION_VERIFY_HOME:-$HOME}
here=$(cd "$(dirname "$0")" && pwd)
root=${WORKSTATION_ENGINE_REPO:-$here/../../..}
# WORKSTATION_ENGINE_REPO is the repo anchor (itself or its workstation child).
[ -f "$root/versions.json" ] || root=$root/workstation
manifest=$root/versions.json
checkout=$home/.hermes/hermes-agent
launcher=$checkout/.hermes/bin/hermes

fail() {
  echo "hermes verify: $1" >&2
  exit 1
}

[ -f "$manifest" ] || fail "versions manifest not found at $manifest (set WORKSTATION_ENGINE_REPO)"
command -v git >/dev/null 2>&1 || fail "git not on PATH; cannot verify the pinned checkout"

pin_commit=$(sed -n 's/.*"hermes_agent_git_commit":[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -n 1)
[ -n "$pin_commit" ] || fail "hermes_agent_git_commit pin missing from $manifest"

[ -d "$checkout" ] || fail "hermes checkout missing at $checkout (run: workstation apply)"
head=$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)
[ -n "$head" ] || fail "$checkout is not a git checkout (engine-provisioned pinned clone expected)"
[ "$head" = "$pin_commit" ] || fail "checkout HEAD $head does not carry the pinned commit $pin_commit"

[ -f "$launcher" ] || fail "launcher missing at $launcher"
[ -x "$launcher" ] || fail "launcher at $launcher is not executable"
"$launcher" --version >/dev/null 2>&1 || fail "launcher --version failed at $launcher"

[ -f "$home/.hermes/skills/secrets/SKILL.md" ] ||
  fail "managed skill missing at $home/.hermes/skills/secrets/SKILL.md"

echo "hermes verify: ok — $checkout is at the pinned commit $pin_commit; launcher and managed skills present"
