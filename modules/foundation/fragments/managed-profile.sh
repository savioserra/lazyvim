# Workstation foundation fragment: load the managed profile in login shells.
# shellcheck source=/dev/null
[ -r "$HOME/.profile" ] && . "$HOME/.profile"
