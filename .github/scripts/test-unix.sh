#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="${GITHUB_WORKSPACE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
scratch="${1:?usage: test-unix.sh SCRATCH_HOME}"

export HOME="$scratch"
export XDG_CONFIG_HOME="$scratch/.config"
export XDG_DATA_HOME="$scratch/.local/share"
export XDG_STATE_HOME="$scratch/.local/state"
export XDG_CACHE_HOME="$scratch/.cache"
export PATH="$scratch/.local/bin:$PATH"
export CHEZMOI_DESTDIR="$scratch"
export CHEZMOI_SYNC_APPLY_ONLY=1

mkdir -p "$scratch"
"$repo_root/sync"

assert_eq() {
  local actual="$1"
  local expected="$2"
  local description="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf '%s: expected %q, got %q\n' "$description" "$expected" "$actual" >&2
    return 1
  fi
}

assert_starts_with() {
  local actual="$1"
  local expected="$2"
  local description="$3"
  if [[ "$actual" != "$expected"* ]]; then
    printf '%s: expected prefix %q, got %q\n' "$description" "$expected" "$actual" >&2
    return 1
  fi
}

assert_eq "$("$scratch/.local/bin/nvim" --version | head -1)" "NVIM v0.12.4" "Neovim version"
[[ $("$scratch/.local/bin/go" version) == go\ version\ go1.27.0* ]] || {
  "$scratch/.local/bin/go" version >&2
  exit 1
}
bash -lc 'source "$HOME/.local/opt/nvm/nvm.sh"; [[ $(nvm current) == v24.19.0 ]]; [[ $(node --version) == v24.19.0 ]]; npm --version'
assert_starts_with "$("$scratch/.local/bin/rg" --version | head -1)" "ripgrep 15.2.0" "ripgrep version"
"$scratch/.local/bin/fd" --version | grep -F 'fd 10.'
assert_eq "$("$scratch/.local/bin/fzf" --version | awk '{print $1}')" "0.74.2" "fzf version"
"$scratch/.local/bin/lazygit" --version | grep -F 'version=0.63.1'
"$scratch/.local/bin/tree-sitter" --version | grep -F '0.26.11'

plugins="$scratch/.tmux/plugins"
while read -r _ name _ commit; do
  [[ $(git -C "$plugins/$name" rev-parse HEAD) == "$commit" ]]
done < <(grep '^install ' "$repo_root/home/.chezmoiscripts/run_onchange_after_30-tmux-plugins.sh.tmpl")

tmux -L ci -f "$scratch/.tmux.conf" new-session -d -s ci
trap 'tmux -L ci kill-server 2>/dev/null || true' EXIT
tmux -L ci display-message -p '#S' | grep -Fx ci
tmux -L ci show-options -gqv @tmux2k-theme | grep -Fx catppuccin
