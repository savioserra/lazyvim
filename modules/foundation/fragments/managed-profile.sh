# Workstation foundation fragment: load the managed profile in login shells.
# shellcheck source=/dev/null
[ -r "$HOME/.profile" ] && . "$HOME/.profile"

# login bash skips .bashrc - chain the interactive lane (the fragments
# above set PATH; this brings the prompt, aliases, hooks)
if [ -n "$BASH_VERSION" ] && [ -r "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi
