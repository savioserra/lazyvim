#!/bin/sh
# Managed by the workstation substrate — the agent capability's A2A
# converge (programs.hermes.a2a), run by the activation.
#
#   workstation-a2a-converge <desired.json> <hermes>
#
# | Input | Meaning |
# | --- | --- |
# | `desired.json` | the declared state (store file, no secret values) |
# | `hermes` | the launcher; every write goes through its CLI |
# | `HERMES_HOME` | the hot home converged (`config.yaml`, `.env`) |
# | `WORKSTATION_STATE` | the state tree holding `hermes-a2a.owned` |
#
# - Reads parse `config.yaml` and `.env` in place; writes run only on
#   drift, through `hermes config set|unset` and `hermes tools
#   enable|disable`, each verified by a re-read.
# - `hermes-a2a.owned` lists the keys the declaration owns; a key that
#   leaves the declaration is retracted, operator keys stay untouched.
# - Secrets: token env names are checked for presence only; no value is
#   read, written or printed. `workstation peers` stores the tokens and
#   leaves `hermes-a2a.restart`, which counts as a change here.
# - A verified change restarts a running gateway, unless this process
#   runs inside it (the restart would take the apply down).
set -u

desired=${1:?usage: workstation-a2a-converge <desired.json> <hermes>}
hermes=${2:?usage: workstation-a2a-converge <desired.json> <hermes>}
home=${HERMES_HOME:?HERMES_HOME unset}
state=${WORKSTATION_STATE:?WORKSTATION_STATE unset}
config=$home/config.yaml
env_file=$home/.env
owned=$state/hermes-a2a.owned
# the service managers the gateway verbs drive (systemctl, launchctl) live
# outside the activation PATH
PATH=$PATH:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH HERMES_HOME

changed=0
failed=0
next=$(mktemp "${TMPDIR:-/tmp}/ws-a2a.XXXXXX") || exit 1
trap 'rm -f "$next"' EXIT

say() {
	printf 'workstation: a2a %s\n' "$*"
}

want() {
	# want <yq expr> — one value of the declared state (canonical json)
	yq -p json -o json -I=0 "$1" "$desired"
}

want_raw() {
	yq -p json -o json -r "$1" "$desired"
}

path_of() {
	# path_of <dotted key> — the bracketed yq path (segments may carry '-')
	printf '%s' "$1" | sed -e 's/[^.][^.]*/["&"]/g' -e 's/\.//g' -e 's/^/./'
}

cfg_get() {
	# cfg_get <yq expr> — one canonical value of config.yaml (null when absent)
	[ -f "$config" ] || {
		printf 'null'
		return 0
	}
	yq -o json -I=0 "($1) | sort_keys(..)" "$config" 2>/dev/null || printf 'null'
}

env_get() {
	# env_get <NAME> — the last assignment of a NON-secret key in .env
	[ -f "$env_file" ] || return 0
	sed -n "s/^$1=//p" "$env_file" | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

env_present() {
	# env_present <NAME> — .env assigns the key a non-empty value (the value
	# itself is never read)
	[ -f "$env_file" ] && grep -Eq "^$1=.+" "$env_file"
}

run() {
	# run <args...> — one hermes CLI write; the last output line on failure
	if out=$("$hermes" "$@" </dev/null 2>&1); then
		return 0
	fi
	say "write failed — hermes $1 $2: $(printf '%s\n' "$out" | tail -n 1)"
	failed=1
	return 1
}

own() {
	printf '%s %s\n' "$1" "$2" >>"$next"
}

converged() {
	# converged <what> — count a verified write, flag one that read back wrong
	if [ "$1" = yes ]; then
		changed=$((changed + 1))
		say "$2"
	else
		say "$2 did not converge (the re-read disagrees)"
		failed=1
	fi
}

ensure_cfg() {
	# ensure_cfg <dotted key> <canonical json> [<yq filter on the read>]
	own cfg "$1"
	expr="$(path_of "$1")${3:-}"
	[ "$(cfg_get "$expr")" = "$2" ] && return 0
	run config set --force "$1" "$2" || return 0
	if [ "$(cfg_get "$expr")" = "$2" ]; then converged yes "set $1"; else converged no "set $1"; fi
}

ensure_env() {
	# ensure_env <NAME> <value>
	own env "$1"
	[ "$(env_get "$1")" = "$2" ] && return 0
	run config set "$1" "$2" || return 0
	if [ "$(env_get "$1")" = "$2" ]; then converged yes "set $1"; else converged no "set $1"; fi
}

toolset_on() {
	[ "$(cfg_get ".platform_toolsets[\"$1\"] | contains([\"a2a\"])")" = true ]
}

ensure_toolset() {
	own tool "$1"
	toolset_on "$1" && return 0
	run tools enable a2a --platform "$1" || return 0
	if toolset_on "$1"; then converged yes "toolset on for $1"; else converged no "toolset on for $1"; fi
}

retract() {
	# retract <kind> <key> — a key the declaration owned and dropped
	case $1 in
	cfg)
		[ "$(cfg_get "$(path_of "$2")")" = null ] && return 0
		run config unset "$2" || return 0
		;;
	env)
		[ -n "$(env_get "$2")" ] || return 0
		run config unset "$2" || return 0
		;;
	tool)
		toolset_on "$2" || return 0
		run tools disable a2a --platform "$2" || return 0
		;;
	*) return 0 ;;
	esac
	changed=$((changed + 1))
	say "retracted $2"
}

inside_gateway() {
	# inside_gateway <pid> — this process descends from the gateway or
	# shares its cgroup (either way a restart takes the apply down)
	pid=$$
	while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
		[ "$pid" = "$1" ] && return 0
		if [ -r "/proc/$pid/status" ]; then
			pid=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$pid/status")
		else
			pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
		fi
	done
	if [ -r /proc/self/cgroup ] && [ -r "/proc/$1/cgroup" ]; then
		[ "$(cat /proc/self/cgroup)" = "$(cat "/proc/$1/cgroup")" ] && return 0
	fi
	return 1
}

# --- the declared keys -------------------------------------------------------
if [ "$(want .enable)" = true ]; then
	port=$(want .port)
	name=$(want_raw .name)
	ensure_cfg platforms.a2a.enabled true
	ensure_cfg platforms.a2a.extra.port "$port"
	for platform in $(want_raw '.platforms[]'); do
		ensure_toolset "$platform"
	done
	[ -n "$name" ] && ensure_env A2A_AGENT_NAME "$name"

	# the tailnet bind: this node's tailnet IPv4. Hermes widens the bind
	# only once an inbound token exists; an unreachable tailnet keeps the
	# current bind untouched.
	bind=''
	if [ "$(want .tailnet)" = true ]; then
		ip=$(tailscale ip -4 2>/dev/null | head -n 1)
		case $ip in
		[0-9]*.[0-9]*.[0-9]*.[0-9]*)
			bind=$ip
			ensure_env A2A_HOST "$ip"
			;;
		*)
			bind=$(env_get A2A_HOST)
			if [ -n "$bind" ]; then
				own env A2A_HOST
				say "tailnet unreachable — the bind stays $bind"
			else
				say "tailnet bind deferred — no tailnet IPv4 (tailscaled down or logged out); serving loopback"
			fi
			;;
		esac
	fi
	if [ -n "$bind" ]; then
		[ -n "$name" ] && ensure_env A2A_PUBLIC_URL "http://$name:$port"
		if ! env_present A2A_PEER_TOKENS && ! env_present A2A_BEARER_TOKEN; then
			say "the tailnet bind waits on a pairing — run: workstation peers (hermes serves loopback until then)"
		fi
	fi

	# the peers: one a2a_agents entry each, trusted inbound by alias
	aliases=$(want_raw '.peers | keys | .[]')
	for alias in $aliases; do
		WS_A2A_ALIAS=$alias
		export WS_A2A_ALIAS
		ensure_cfg "a2a_agents.$alias" "$(want '.peers[strenv(WS_A2A_ALIAS)] | sort_keys(..)')"
		token=$(want_raw '.tokenEnvs[strenv(WS_A2A_ALIAS)]')
		env_present "$token" || say "peer $alias is not paired — run: workstation peers"
	done
	if [ -n "$aliases" ]; then
		ensure_cfg a2a.trusted_peers "$(want '.peers | keys | sort')" ' | sort'
	fi
fi

# --- retraction: owned keys the declaration dropped --------------------------
if [ -f "$owned" ]; then
	while read -r kind key; do
		[ -n "$key" ] || continue
		grep -Fqx "$kind $key" "$next" && continue
		retract "$kind" "$key"
	done <"$owned"
fi

# --- the gateway serves the change -------------------------------------------
# a pairing changes tokens the reads never see: its marker is a change,
# consumed once the gateway serves it (restarted, or not running)
marker=$state/hermes-a2a.restart
if [ -e "$marker" ]; then
	changed=$((changed + 1))
	say "pairing tokens changed"
fi
served=1
if [ "$changed" -gt 0 ]; then
	gw=$("$hermes" gateway list </dev/null 2>/dev/null | sed -n 's/.*(current).*PID \([0-9][0-9]*\).*/\1/p' | head -n 1)
	if [ -z "$gw" ]; then
		say "$changed key(s) changed — the gateway is not running; its next start serves them"
	elif inside_gateway "$gw"; then
		say "$changed key(s) changed — restart deferred: this apply runs inside the gateway (pid $gw); run: hermes gateway restart"
		served=0
	elif "$hermes" gateway restart </dev/null >/dev/null 2>&1; then
		say "$changed key(s) changed — gateway restarted"
	else
		say "$changed key(s) changed — gateway restart failed; run: hermes gateway restart"
		served=0
		failed=1
	fi
fi
[ "$served" = 1 ] && rm -f "$marker"

# the ownership record moves only on a clean run: a failed write retries
# against the previous record at the next apply
if [ "$failed" = 0 ]; then
	mkdir -p "$state" && sort -u "$next" >"$owned"
	exit 0
fi
exit 1
