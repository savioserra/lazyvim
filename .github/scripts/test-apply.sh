#!/bin/sh
set -eu
scratch_home=$1
repo_root=${GITHUB_WORKSPACE:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}
export HOME=$scratch_home CHEZMOI_DESTDIR=$scratch_home XDG_CONFIG_HOME=$scratch_home/.config XDG_DATA_HOME=$scratch_home/.local/share XDG_STATE_HOME=$scratch_home/.local/state XDG_CACHE_HOME=$scratch_home/.cache
node_version=$(cat "$repo_root/chezmoi/dot_node-version")
nvim=$scratch_home/.local/opt/nvim/bin/nvim
node=$scratch_home/.local/opt/nvm/versions/node/v$node_version/bin/node
npm=$scratch_home/.local/opt/nvm/versions/node/v$node_version/bin/npm
stylua=$XDG_DATA_HOME/nvim/mason/bin/stylua
# TASK-34 phase 1: the engine no longer deploys through chezmoi. Chezmoi
# materializes home state only; the lifecycle runs from the repository engine
# against the scratch home. Phase 3 replaces this with the workstation CLI.
chezmoi --source "$repo_root/chezmoi" --destination "$scratch_home" apply --force --exclude scripts
"$nvim" -l "$repo_root/tests/capabilities.test.lua"
"$nvim" -l "$repo_root/workstation/apps/cli/run.lua" setup
"$nvim" -l "$repo_root/workstation/apps/cli/run.lua" sync
"$stylua" --check --config-path "$repo_root/.stylua.toml" "$repo_root/workstation" "$repo_root/chezmoi/dot_config/nvim" "$repo_root/tests"
"$nvim" -l "$repo_root/workstation/apps/cli/run.lua" verify
