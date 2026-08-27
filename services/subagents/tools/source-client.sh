#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd -P)
service="$repo/services/subagents"
uid=$(id -u)
root=${WS_SUBAGENTS_CLIENT_ROOT:-"${TMPDIR:-/tmp}/ws-subagents-client-$uid"}
case "$root" in /tmp/ws-subagents-client-*|/private/tmp/ws-subagents-client-*) ;; *) echo "refusing non-temporary client root: $root" >&2; exit 2;; esac
server="ws-subagents-client-$uid"
socket="$root/run/control.sock"
config="$root/config/config.toml"
admin="$root/credentials/admin.json"
pidfile="$root/daemon.pid"
client_extension="$repo/home/dot_pi/private_agent/extensions/actor-client/index.ts"

need(){ command -v "$1" >/dev/null 2>&1||{ echo "missing required command: $1" >&2;exit 2;};}
private_dirs(){ umask 077;mkdir -p "$root" "$root/bin" "$root/run" "$root/config" "$root/state" "$root/sessions" "$root/credentials" "$root/xdg-state" "$root/xdg-config" "$root/worktrees";chmod 700 "$root" "$root/bin" "$root/run" "$root/config" "$root/state" "$root/sessions" "$root/credentials" "$root/xdg-state" "$root/xdg-config" "$root/worktrees";}
exact_pid(){ [ -f "$pidfile" ]||return 1;pid=$(cat "$pidfile");case "$pid" in *[!0-9]*|'') return 1;;esac;kill -0 "$pid" 2>/dev/null||return 1;[ "$(readlink "/proc/$pid/exe" 2>/dev/null||true)" = "$root/bin/subagents" ]||return 1;}
validate_agent(){ case "$1" in ''|*[!A-Za-z0-9_-]*) echo "invalid actor id" >&2;exit 2;;esac;[ "${#1}" -le 64 ]||{ echo "actor id too long" >&2;exit 2;};}
validate_project(){ [ "${1#/}" != "$1" ]&&[ -d "$1" ]&&[ ! -L "$1" ]||{ echo "project must be an existing absolute non-symlink directory" >&2;exit 2;};}
write_config(){
  tmux_bin=$(command -v tmux);pi_bin=$(command -v pi);bridge="$repo/home/dot_pi/private_agent/extensions/hosted-pi-bridge/index.ts";tmux_conf="$root/tmux.conf";: >"$tmux_conf";chmod 600 "$tmux_conf"
  for value in "$tmux_bin" "$pi_bin" "$bridge" "$root" "$repo";do case "$value" in *'"'*|*\\*|*'
'*) echo "unsupported path character in $value" >&2;exit 2;;esac;done
  cat >"$config" <<EOF
schema_version = 1
[service]
enabled = true
[hosted_pi]
enabled = true
tmux_binary = "$tmux_bin"
pi_binary = "$pi_bin"
bridge_extension = "$bridge"
tmux_server_name = "$server"
tmux_config = "$tmux_conf"
state_directory = "$root/state"
pi_session_directory = "$root/sessions"
credential_directory = "$root/credentials"
admin_credential_file = "$admin"
default_project_directory = "$repo"
trust_project = true
[remoting]
enabled = false
node_identity = ""
bind_host = ""
port = 0
allowed_cidrs = []
address_families = []
mtls_identity = ""
ca_file = ""
cert_file = ""
key_file = ""
peers = []
EOF
  chmod 600 "$config"
}
ctl(){ operation=$1;agent=$2;project=$3;"$root/bin/clientctl" -socket "$socket" -credential "$admin" -operation "$operation" -agent "$agent" -project "$project" -trust-project;}
up(){
  need go;need npm;need tmux;need pi;need setsid;need nohup;private_dirs
  if exact_pid;then echo "client daemon already running (pid $(cat "$pidfile"))";return;fi
  rm -f "$pidfile" "$socket";write_config
  (cd "$service"&&npm ci --ignore-scripts --no-audit --no-fund >/dev/null)
  (cd "$repo/home/dot_pi/private_agent/extensions/hosted-pi-bridge"&&npm ci --omit=dev --ignore-scripts --no-audit --no-fund >/dev/null)
  (cd "$repo/home/dot_pi/private_agent/extensions/actor-client"&&npm ci --omit=dev --ignore-scripts --no-audit --no-fund >/dev/null)
  (cd "$service"&&go build -o "$root/bin/subagents" ./cmd/subagents&&go build -o "$root/bin/clientctl" ./tools/clientctl)
  setsid nohup env XDG_RUNTIME_DIR="$root/run" XDG_STATE_HOME="$root/xdg-state" XDG_CONFIG_HOME="$root/xdg-config" "$root/bin/subagents" -config "$config" -socket "$socket" </dev/null >"$root/daemon.log" 2>&1 &
  pid=$!;printf '%s\n' "$pid">"$pidfile";chmod 600 "$pidfile";tries=0
  while [ ! -S "$socket" ]||[ ! -f "$admin" ];do tries=$((tries+1));[ "$tries" -lt 100 ]||{ cat "$root/daemon.log" >&2;exit 1;};kill -0 "$pid" 2>/dev/null||{ cat "$root/daemon.log" >&2;exit 1;};sleep 0.05;done
  echo "client daemon ready: $socket"
  echo "regular Pi: $0 client"
}
start(){ [ "$#" -eq 2 ]||{ echo "usage: $0 start AGENT /absolute/worktree" >&2;exit 2;};agent=$1;project=$2;validate_agent "$agent";validate_project "$project";up;response=$(ctl start "$agent" "$project");printf '%s\n' "$response";target=$(printf '%s\n' "$response"|python3 -c 'import json,sys;print(json.load(sys.stdin)["attach_target"])');echo "attach: tmux -L $server attach-session -t '$target'";}
status(){ [ "$#" -eq 1 ]||{ echo "usage: $0 status AGENT" >&2;exit 2;};validate_agent "$1";ctl status "$1" "$repo";}
stop(){ [ "$#" -eq 1 ]||{ echo "usage: $0 stop AGENT" >&2;exit 2;};validate_agent "$1";ctl stop "$1" "$repo";}
attach(){ response=$(status "$1");target=$(printf '%s\n' "$response"|python3 -c 'import json,sys;print(json.load(sys.stdin)["attach_target"])');[ -n "$target" ]||{ echo "agent has no attach target" >&2;exit 1;};exec tmux -L "$server" attach-session -t "$target";}
client(){ up;exec env WS_SUBAGENTS_CLIENT_SOCKET="$socket" WS_SUBAGENTS_CLIENT_ADMIN_CREDENTIAL_FILE="$admin" WS_SUBAGENTS_CLIENT_TMUX_SERVER="$server" pi -e "$client_extension";}
worktree_add(){ [ "$#" -eq 2 ]||{ echo "usage: $0 worktree-add /trusted/repository NAME" >&2;exit 2;};trusted=$1;name=$2;validate_agent "$name";[ "${trusted#/}" != "$trusted" ]&&[ -d "$trusted/.git" -o -f "$trusted/.git" ]||{ echo "trusted repository must be an absolute git repository" >&2;exit 2;};private_dirs;destination="$root/worktrees/$name";[ ! -e "$destination" ]||{ echo "client worktree already exists" >&2;exit 2;};git -C "$trusted" worktree add --detach "$destination" HEAD;printf '%s\n' "$destination";}
down(){ if exact_pid;then pid=$(cat "$pidfile");kill -TERM "$pid";tries=0;while kill -0 "$pid" 2>/dev/null;do tries=$((tries+1));[ "$tries" -lt 200 ]||break;sleep 0.05;done;fi;rm -f "$pidfile";echo "client daemon stopped; isolated state retained at $root";}
case "${1:-}" in up) up;;start) shift;start "$@";;status) shift;status "$@";;stop) shift;stop "$@";;attach) shift;attach "$@";;client) client;;worktree-add) shift;worktree_add "$@";;down) down;;clean) down;case "$root" in /tmp/ws-subagents-client-*|/private/tmp/ws-subagents-client-*) rm -rf -- "$root";;esac;;*) echo "usage: $0 {up|client|start AGENT PROJECT|status AGENT|attach AGENT|stop AGENT|worktree-add REPO NAME|down|clean}" >&2;exit 2;;esac
