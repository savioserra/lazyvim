# Managed by chezmoi. Activate mise in shells that have an activate hook
# (bash, zsh); plain sh has no activate variant, so it stays a no-op there —
# version resolution rides the managed default config and each project's
# .tool-versions either way.
if command -v mise >/dev/null 2>&1; then
  if [ -n "${ZSH_VERSION:-}" ]; then
    eval "$(mise activate zsh)"
  elif [ -n "${BASH_VERSION:-}" ]; then
    eval "$(mise activate bash)"
  fi
fi
