#!/bin/sh
# prompt verify — the dissolved capability's consumer smoke (read-only).
#
# The prompt capability dissolved into the foundation domain (operator
# ruling 2026-10-22): eza and starship are nixpkgs packages, the starship
# config deploys from the foundation module, and the managed rc fragments
# source from .config/workstation/shell/. This script asserts the host
# carries the result: both tools on PATH and SPEAKING, the starship
# payload deployed, and the rc lane wired — markers present per shell and
# the per-shell starship init exact in the fragment files (the walker's
# id-keyed file map used to collapse the two bodies; the declared lane
# gives each shell its own). The engine never runs this script; it is the
# host lane's assertion surface (docs/capabilities.md "Package payload
# rule"). Exits nonzero with a message on the first failed assertion.
set -eu

home=${WORKSTATION_VERIFY_HOME:-$HOME}

fail() {
  echo "prompt verify: $1" >&2
  exit 1
}

# eza + starship: on PATH and speaking (nixpkgs-owned — no pin rows to
# check anymore, the consumer smoke IS the assertion).
command -v eza >/dev/null 2>&1 || fail "eza is not on PATH (run: workstation apply)"
command -v starship >/dev/null 2>&1 || fail "starship is not on PATH (run: workstation apply)"
eza --version >/dev/null 2>&1 || fail "eza does not speak"
first=$(starship --version 2>/dev/null | head -n 1)
echo "$first" | grep -Eq '^starship [0-9]' ||
  fail "starship reports \`$first\`, expected a version line"
echo "prompt verify: ok — eza and starship ($first) on PATH and speaking"

# The starship payload: deployed by the foundation module.
[ -r "$home/.config/starship.toml" ] ||
  fail "the starship config is missing at $home/.config/starship.toml"
echo "prompt verify: ok — starship config deployed"

# The managed rc fragments: markers present per shell, per-shell init
# exact in the fragment files. The grep patterns quote the literal lines
# — the $( in them is data.
for rc in .bashrc .zshrc; do
  grep -Fqx "# workstation: managed eza ls" "$home/$rc" ||
    fail "$rc carries no managed-eza fragment (run: workstation apply)"
  grep -Fqx "# workstation: managed starship prompt" "$home/$rc" ||
    fail "$rc carries no managed-starship fragment (run: workstation apply)"
done
# shellcheck disable=SC2016
grep -Fqx 'command -v starship >/dev/null 2>&1 && eval "$(starship init bash)"' \
  "$home/.config/workstation/shell/managed-starship.sh" ||
  fail "the bash fragment does not init starship for bash"
# shellcheck disable=SC2016
grep -Fqx 'command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"' \
  "$home/.config/workstation/shell/managed-starship-zsh.sh" ||
  fail "the zsh fragment does not init starship for zsh"
grep -Fq "alias ls='eza -lh --group-directories-first --icons=auto'" \
  "$home/.config/workstation/shell/managed-eza.sh" ||
  fail "the eza fragment does not alias ls to eza"
echo "prompt verify: ok — managed-eza and managed-starship wired into .bashrc and .zshrc"

echo "prompt verify: the prompt surface is provisioned and speaking"
