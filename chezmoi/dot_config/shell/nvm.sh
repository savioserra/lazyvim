# Managed by chezmoi. Load nvm and its pinned default Node version.
export NVM_DIR="$HOME/.local/opt/nvm"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  # shellcheck source=/dev/null
  . "$NVM_DIR/nvm.sh"
fi
