#!/bin/sh
# prompt package verify — the pinned-tool consumer smoke (read-only).
#
# Asserts the package's features resolve on the host: the eza and starship
# trees are engine-provisioned at their pins (.local/opt/<tool>, download
# recipes), surfaced at .local/bin/<tool>, and SPEAK — starship's exec probe
# carries the pinned version on the first --version line; eza's version line
# is not on the first line (`eza --version` leads with the tagline), so its
# identity is held through the content probe: the binary's sha256 must equal
# the manifest's member digest (the versions.json `eza_bin_linux_x86_64`
# inventory pin). The managed rc fragments must be wired into both
# interactive shells — the guarded alias keeps plain `ls` where eza is
# absent. The engine never runs this script; it is the host lane's
# assertion surface (docs/capabilities.md "Package payload rule"). Exits
# nonzero with a message on the first failed assertion.
set -eu

home=${WORKSTATION_VERIFY_HOME:-$HOME}
here=$(cd "$(dirname "$0")" && pwd)
root=${WORKSTATION_ENGINE_REPO:-$here/../../../..}
# WORKSTATION_ENGINE_REPO is the repo anchor (itself or its workstation child).
[ -f "$root/versions.json" ] || root=$root/workstation
manifest=$root/packages/terminal/prompt/manifest.json
versions=$root/versions.json

fail() {
  echo "prompt verify: $1" >&2
  exit 1
}

[ -f "$manifest" ] || fail "prompt package manifest not found at $manifest (set WORKSTATION_ENGINE_REPO)"
[ -f "$versions" ] || fail "versions manifest not found at $versions (set WORKSTATION_ENGINE_REPO)"

# The declared pins, read back from the manifests (the catalog test asserts
# the manifest mirrors versions.json; here both must agree with the home).
starship_version=$(sed -n 's/^  "starship": "\([^"]*\)".*/\1/p' "$versions")
[ -n "$starship_version" ] || fail "no starship version pin in $versions"
eza_member_sha=$(awk '/"member": "eza"/ {inget = 1; next} inget && /"sha256":/ { match($0, /"sha256": "[0-9a-f]*"/); print substr($0, RSTART + 11, RLENGTH - 12); exit }' "$manifest")
[ -n "$eza_member_sha" ] || fail "no eza content-probe member digest in $manifest"

# eza: provisioned tree, surfaced launcher, pinned bytes, working binary.
eza_bin=$home/.local/opt/eza/eza
[ -f "$eza_bin" ] || fail "eza tree missing at $eza_bin (run: workstation apply)"
[ -x "$eza_bin" ] || fail "$eza_bin is not executable"
actual=$(sha256sum "$eza_bin" | cut -d' ' -f1)
[ "$actual" = "$eza_member_sha" ] || fail "$eza_bin hashes to $actual, expected the pinned member digest $eza_member_sha"
"$home/.local/bin/eza" --version >/dev/null 2>&1 || fail "eza does not speak through $home/.local/bin/eza"
echo "prompt verify: ok — eza at the pinned bytes ($eza_bin)"

# starship: provisioned tree, surfaced launcher, exec probe carries the pin.
starship_bin=$home/.local/opt/starship/starship
[ -f "$starship_bin" ] || fail "starship tree missing at $starship_bin (run: workstation apply)"
[ -x "$starship_bin" ] || fail "$starship_bin is not executable"
first=$("$home/.local/bin/starship" --version 2>/dev/null | head -n 1)
echo "$first" | grep -Eq "^starship $starship_version( |$)" ||
  fail "starship reports \`$first\`, expected the pinned version $starship_version"
echo "prompt verify: ok — starship $starship_version ($starship_bin)"

# The managed rc fragments: markers present, per-shell starship init exact.
# The grep patterns quote the literal rc lines — the $( in them is data.
for rc in .bashrc .zshrc; do
  grep -Fqx "# chezmoi: managed eza ls" "$home/$rc" ||
    fail "$rc carries no managed-eza fragment (run: workstation apply)"
  grep -Fqx "# chezmoi: managed starship prompt" "$home/$rc" ||
    fail "$rc carries no managed-starship fragment (run: workstation apply)"
done
# shellcheck disable=SC2016
grep -Fqx 'command -v starship >/dev/null 2>&1 && eval "$(starship init bash)"' "$home/.bashrc" ||
  fail ".bashrc does not init starship for bash"
# shellcheck disable=SC2016
grep -Fqx 'command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"' "$home/.zshrc" ||
  fail ".zshrc does not init starship for zsh"
grep -Fq "alias ls='eza -lh --group-directories-first --icons=auto'" "$home/.bashrc" ||
  fail ".bashrc does not alias ls to eza"
echo "prompt verify: ok — managed-eza and managed-starship wired into .bashrc and .zshrc"

echo "prompt verify: the prompt package is provisioned and speaking"
