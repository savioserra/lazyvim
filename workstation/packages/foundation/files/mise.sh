# Managed by chezmoi. Activate the engine-managed mise in shells that have
# an activate hook (bash, zsh); plain sh has no activate variant, so it
# stays a no-op there — version resolution rides the engine's managed
# config and each project's .tool-versions either way.
#
# The engine owns the mise footprint end to end: the pinned binary lives
# in the engine's opt root (.local/opt/mise/<version>/bin/mise) and the
# engine's apply keeps the ~/.local/bin/mise symlink aimed at the current
# pin. This fragment activates THE ENGINE'S BINARY by absolute path and
# never a bare `mise` from PATH: PATH resolution binds whatever mise ranks
# first (on a host with a distro mise under /usr/bin that is never the
# engine's), and a foreign mise version paired with the engine's managed
# data and config split-brains every project tool resolution (the
# 2026-10-20 omarchy failure). Resolution order: the engine launcher
# symlink — honored only in its contract shape (../opt/mise/<version>/
# bin/mise), so a stray or foreign link is refused — else the sole
# opt-root pin (found with find, so zsh never trips an unmatched glob);
# anything else — an ambiguous multi-pin tree, an absent tree, a foreign
# file at the launcher path — activates nothing, because the engine's
# data and config are never handed to a non-engine mise. Both variables
# are mise-namespaced, so nothing outside mise sees them.
mise_engine_bin=
if [ -L "$HOME/.local/bin/mise" ]; then
  mise_link=$(readlink "$HOME/.local/bin/mise" 2>/dev/null || true)
  case $mise_link in
    ../opt/mise/*/bin/mise)
      mise_version=${mise_link#../opt/mise/}
      mise_version=${mise_version%/bin/mise}
      mise_engine_bin=$HOME/.local/opt/mise/$mise_version/bin/mise
      ;;
  esac
fi
if [ ! -x "$mise_engine_bin" ]; then
  mise_engine_bin=$(
    find "$HOME/.local/opt/mise" -type f -path '*/bin/mise' -perm -u+x 2>/dev/null |
      head -n 2
  )
  case $mise_engine_bin in
    # exactly one pin: keep it; none, or several (a superseded pin's tree
    # still on disk): refuse rather than guess
    '' | *'
'*) mise_engine_bin= ;;
  esac
fi
if [ -n "$mise_engine_bin" ]; then
  MISE_DATA_DIR="$HOME/.local/state/workstation/mise"
  MISE_CONFIG_DIR="$HOME/.config/mise"
  export MISE_DATA_DIR MISE_CONFIG_DIR
  if [ -n "${ZSH_VERSION:-}" ]; then
    eval "$("$mise_engine_bin" activate zsh)"
  elif [ -n "${BASH_VERSION:-}" ]; then
    eval "$("$mise_engine_bin" activate bash)"
  fi
fi
unset mise_engine_bin mise_link mise_version
