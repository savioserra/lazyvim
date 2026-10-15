#!/bin/sh
# agent package verify — the hermes provisioning contract (read-only smoke).
#
# The engine provisions the FULL stack (operator ruling 2026-10-15,
# superseding the documented-host-prerequisite split that t_bf0c0acc
# landed): a converged host carries
#
#   ~/.hermes/hermes-agent        the pinned git checkout (resources)
#   ~/.hermes/skills/secrets      the managed skills (resources)
#   ~/.local/opt/hermes/python    the pinned interpreter (runtime pin)
#   ~/.local/opt/hermes/bin/hermes  the engine launcher (runtime)
#   ~/.local/bin/hermes -> ../opt/hermes/bin/hermes  the PATH entry
#
# and this script asserts all of it on EVERY host, ending in the consumer
# smoke: the launcher reports `hermes --version` with exit 0. An absent or
# broken runtime is provisioning drift — exit 1, never a documented state.
#
# The engine never runs this script; it is the host lane's assertion surface
# (docs/capabilities.md "Package payload rule"). Exits nonzero with a
# message on the first failed assertion.
set -eu

home=${WORKSTATION_VERIFY_HOME:-$HOME}
here=$(cd "$(dirname "$0")" && pwd)
root=${WORKSTATION_ENGINE_REPO:-$here/../../..}
# WORKSTATION_ENGINE_REPO is the repo anchor (itself or its workstation child).
[ -f "$root/versions.json" ] || root=$root/workstation
manifest=$root/versions.json
checkout=$home/.hermes/hermes-agent
python=$home/.local/opt/hermes/python/bin/python3
launcher=$home/.local/bin/hermes

fail() {
  echo "hermes verify: $1" >&2
  exit 1
}

[ -f "$manifest" ] || fail "versions manifest not found at $manifest (set WORKSTATION_ENGINE_REPO)"
command -v git >/dev/null 2>&1 || fail "git not on PATH; cannot verify the pinned checkout"

pin_commit=$(sed -n 's/.*"hermes_agent_git_commit":[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -n 1)
[ -n "$pin_commit" ] || fail "hermes_agent_git_commit pin missing from $manifest"
pin_python=$(sed -n 's/.*"hermes_python":[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -n 1)
[ -n "$pin_python" ] || fail "hermes_python pin missing from $manifest"

# Resources: the pinned checkout and the managed skills.
[ -d "$checkout" ] || fail "hermes checkout missing at $checkout (run: workstation apply)"
head=$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)
[ -n "$head" ] || fail "$checkout is not a git checkout (engine-provisioned pinned clone expected)"
[ "$head" = "$pin_commit" ] || fail "checkout HEAD $head does not carry the pinned commit $pin_commit"

[ -f "$home/.hermes/skills/secrets/SKILL.md" ] ||
  fail "managed skill missing at $home/.hermes/skills/secrets/SKILL.md"

# Runtime: the pinned interpreter, the engine launcher, and the consumer smoke.
# The smoke runs with HOME anchored at the verify home: the launcher resolves
# its interpreter and checkout from $HOME, exactly as a converged host's
# interactive shell would.
[ -x "$python" ] || fail "pinned interpreter missing at $python (the hermes_python download pin did not apply)"
[ -f "$home/.local/opt/hermes/bin/hermes" ] ||
  fail "engine launcher missing at $home/.local/opt/hermes/bin/hermes (the agent package did not apply)"
[ -x "$launcher" ] || fail "launcher at $launcher is not executable"
smoke=$(timeout 120 env HOME="$home" "$launcher" --version 2>/dev/null | head -n 1) ||
  fail "launcher --version failed at $launcher (broken launcher or interpreter)"
[ -n "$smoke" ] || fail "launcher --version produced no output at $launcher"

echo "hermes verify: full-stack ok — $checkout is at the pinned commit $pin_commit; interpreter $pin_python; smoke: $smoke"
