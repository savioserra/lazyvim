# Managed by chezmoi. Activate the engine-managed mise in shells that have
# an activate hook (bash, zsh); plain sh has no activate variant, so it
# stays a no-op there — version resolution rides the engine's managed
# config and each project's .tool-versions either way.
#
# The engine owns the mise footprint: the binary lives in the engine's opt
# root (surfaced on PATH as ~/.local/bin/mise), tool state lives under the
# engine state root, and the global tool set is the engine's composed
# config. Both variables are mise-namespaced, so nothing outside mise sees
# them.
MISE_DATA_DIR="$HOME/.local/state/workstation/mise"
MISE_CONFIG_DIR="$HOME/.config/mise"
export MISE_DATA_DIR MISE_CONFIG_DIR
if command -v mise >/dev/null 2>&1; then
  if [ -n "${ZSH_VERSION:-}" ]; then
    eval "$(mise activate zsh)"
  elif [ -n "${BASH_VERSION:-}" ]; then
    eval "$(mise activate bash)"
  fi
fi
