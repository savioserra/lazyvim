#!/bin/sh
# agent verify — the hermes provisioning contract (read-only smoke).
#
# The agent capability provisions the FULL stack (operator ruling
# 2026-10-15: resources-without-runtime is a defect, not a documented
# manual step). A converged host carries
#
#   ~/.local/opt/hermes/pin.json     the deployed pin manifest (the anchor)
#   ~/.hermes/hermes-agent           the pinned checkout (resources, hot)
#   ~/.hermes/skills/<declared>      the declared skills (store symlinks)
#   ~/.local/opt/hermes/python       the pinned interpreter (runtime pin)
#   ~/.local/opt/hermes/bin/hermes   the engine launcher (runtime)
#   ~/.local/bin/hermes              the PATH entry
#
# and this script asserts all of it on EVERY host, ending in the consumer
# smoke: the launcher reports `hermes --version` with exit 0. The pin
# anchor is the DEPLOYED manifest (programs.hermes.pin's bytes, rendered by
# the agent module) — never a repo file. An absent or broken runtime is
# provisioning drift — exit 1, never a documented state.
#
# The engine never runs this script; it is the host lane's assertion surface
# (docs/capabilities.md "Payload rule"). Exits nonzero with a message on the
# first failed assertion.
set -eu

home=${WORKSTATION_VERIFY_HOME:-$HOME}
pin_manifest=$home/.local/opt/hermes/pin.json
checkout=$home/.hermes/hermes-agent
python=$home/.local/opt/hermes/python/bin/python3
launcher=$home/.local/bin/hermes

fail() {
  echo "hermes verify: $1" >&2
  exit 1
}

[ -r "$pin_manifest" ] || fail "pin manifest missing at $pin_manifest (the agent capability did not apply)"
command -v git >/dev/null 2>&1 || fail "git not on PATH; cannot verify the pinned checkout"

pin_commit=$(sed -n 's/.*"engine":{"rev":"\([0-9a-f]\{40\}\)".*/\1/p' "$pin_manifest" | head -n 1)
[ -n "$pin_commit" ] || fail "engine rev missing or malformed in $pin_manifest"
pin_python=$(sed -n 's/.*"python":"\([^"]*\)".*/\1/p' "$pin_manifest" | head -n 1)
[ -n "$pin_python" ] || fail "python pin missing from $pin_manifest"

# Resources: the pinned checkout and the declared skills.
[ -d "$checkout" ] || fail "hermes checkout missing at $checkout (run: workstation apply)"
head=$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)
[ -n "$head" ] || fail "$checkout is not a git checkout (pinned clone expected)"
[ "$head" = "$pin_commit" ] || fail "checkout HEAD $head does not carry the pinned commit $pin_commit"

# The declared skills: entry symlinks into the store, readable through.
# The copy contract served real trees; the declarative surface serves ONE
# store symlink per skill — anything else here is drift.
[ -L "$home/.hermes/skills/secrets" ] ||
  fail "declared skill at $home/.hermes/skills/secrets is not an entry symlink (copy-contract drift)"
case "$(readlink "$home/.hermes/skills/secrets")" in
  /nix/store/*) ;;
  *) fail "declared skill at $home/.hermes/skills/secrets does not resolve into the store" ;;
esac
[ -f "$home/.hermes/skills/secrets/SKILL.md" ] ||
  fail "declared skill unreadable through the symlink at $home/.hermes/skills/secrets/SKILL.md"
for entry in "$home"/.hermes/skills/*; do
  [ -L "$entry" ] || continue
  case "$(readlink "$entry")" in
    /nix/store/*) ;;
    *) fail "skill entry $entry is a symlink outside the store (undeclared drift)" ;;
  esac
done

# Runtime: the pinned interpreter, the engine launcher, and the consumer smoke.
# The smoke runs with HOME anchored at the verify home: the launcher resolves
# its interpreter and checkout from $HOME, exactly as a converged host's
# interactive shell would.
[ -x "$python" ] || fail "pinned interpreter missing at $python (the hermes_python download pin did not apply)"
[ -f "$home/.local/opt/hermes/bin/hermes" ] ||
  fail "engine launcher missing at $home/.local/opt/hermes/bin/hermes (the agent capability did not apply)"
[ -x "$launcher" ] || fail "launcher at $launcher is not executable"
smoke=$(timeout 120 env HOME="$home" "$launcher" --version 2>/dev/null | head -n 1) ||
  fail "launcher --version failed at $launcher (broken launcher or interpreter)"
[ -n "$smoke" ] || fail "launcher --version produced no output at $launcher"

echo "hermes verify: full-stack ok — $checkout is at the pinned commit $pin_commit; interpreter $pin_python; smoke: $smoke"
