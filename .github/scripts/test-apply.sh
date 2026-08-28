#!/bin/sh
set -eu
scratch_home=$1
repo_root=${GITHUB_WORKSPACE:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}
export HOME=$scratch_home CHEZMOI_DESTDIR=$scratch_home XDG_CONFIG_HOME=$scratch_home/.config XDG_DATA_HOME=$scratch_home/.local/share XDG_STATE_HOME=$scratch_home/.local/state XDG_CACHE_HOME=$scratch_home/.cache
node_version=$(cat "$repo_root/home/dot_node-version")
nvim=$scratch_home/.local/opt/nvim/bin/nvim
node=$scratch_home/.local/opt/nvm/versions/node/v$node_version/bin/node
npm=$scratch_home/.local/opt/nvm/versions/node/v$node_version/bin/npm
stylua=$XDG_DATA_HOME/nvim/mason/bin/stylua
chezmoi --source "$repo_root" --destination "$scratch_home" apply --force
"$stylua" --check --config-path "$repo_root/.stylua.toml" "$repo_root/home/dot_local/share/workstation" "$repo_root/home/dot_config/nvim" "$repo_root/tests"
"$nvim" -l "$repo_root/tests/capabilities.test.lua"
"$npm" ci --omit=dev --ignore-scripts --no-audit --no-fund --prefix "$repo_root/home/dot_pi/private_agent/extensions/tmux-subagents"
find "$repo_root/tests/tmux-subagents" -name '*.test.ts' -print0 | xargs -0 "$node" --test
"$nvim" -l "$scratch_home/.local/share/workstation/apps/cli/run.lua" verify
