# shellcheck disable=SC3043,SC3045 # sourced by bash and zsh: local and read -t are theirs
tmux() {
  command tmux "$@"
  local _rc=$?
  read -t 0.5 -r _ </dev/tty 2>/dev/null
  return $_rc
}
