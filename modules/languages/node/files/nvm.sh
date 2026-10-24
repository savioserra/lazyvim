# Managed by chezmoi. Load nvm and activate the engine-pinned default Node
# version, so fresh and reconciled hosts always resolve `node` on PATH.
export NVM_DIR="$HOME/.local/opt/nvm"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  # shellcheck source=/dev/null
  . "$NVM_DIR/nvm.sh"
fi

# nvm only defines its shell function on load: a freshly provisioned tree
# ships no default alias, so interactive shells would get `nvm` but never
# `node` (the provisioned-but-dead failure class). Activate the pinned
# default here: resolve the recorded default alias, fall back to the sole
# provisioned version (seeding that alias through nvm once), and export the
# PATH, NVM_BIN and NVM_INC state `nvm use` would set — without paying its
# fork cost in every shell. An activation earlier in the shell (an explicit
# `nvm use`) always wins.
if [ -z "${NVM_BIN:-}" ] && [ -d "$NVM_DIR/versions/node" ]; then
  nvm_default=
  if [ -r "$NVM_DIR/alias/default" ]; then
    IFS= read -r nvm_default <"$NVM_DIR/alias/default"
  fi
  if [ -n "$nvm_default" ]; then
    nvm_default="$NVM_DIR/versions/node/$nvm_default"
    [ -x "$nvm_default/bin/node" ] || nvm_default=
  fi
  if [ -z "$nvm_default" ]; then
    for nvm_entry in "$NVM_DIR"/versions/node/*; do
      [ -x "$nvm_entry/bin/node" ] || continue
      if [ -n "$nvm_default" ]; then
        nvm_default=
        break
      fi
      nvm_default=$nvm_entry
    done
    if [ -n "$nvm_default" ] && [ ! -e "$NVM_DIR/alias/default" ]; then
      nvm alias default "${nvm_default##*/}" >/dev/null 2>&1
    fi
  fi
  if [ -n "$nvm_default" ]; then
    PATH="$nvm_default/bin:$PATH"
    export PATH
    NVM_BIN="$nvm_default/bin"
    export NVM_BIN
    NVM_INC="$nvm_default/include/node"
    export NVM_INC
    hash -r
  fi
  unset nvm_default nvm_entry
fi
