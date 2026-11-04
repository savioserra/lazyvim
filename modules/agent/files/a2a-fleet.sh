#!/bin/sh
# Managed by the workstation substrate — the agent capability's A2A fleet
# (programs.hermes.a2a.fleet): members pair automatically over the tailnet.
#
#   workstation-fleet serve    the member listener (the user service)
#   workstation-fleet join     pair with every member on the tailnet
#   workstation-fleet status   this node and the members it pairs with
#   workstation-fleet online   exit 0 when the tailnet runs and is logged in
#   workstation-fleet login    the operator's tailscale login (tailscale up)
#
# | Endpoint (tailnet IPv4, `<port>`) | Answer |
# | --- | --- |
# | `GET /fleet` | `workstation-fleet v1 member=<node>` — the discovery marker |
# | `POST /join` | a fresh pair token for the caller (`member=<node>` + `token=<hex>`) |
#
# - Trust is the tailnet: the caller is identified by `tailscale whois`
#   (WireGuard-authenticated) and accepted only when it belongs to this
#   node's tailscale user; shared-in nodes and other users are refused.
# - A pairing stores both ends the same way: the token through
#   workstation-a2a-token (stdin, never argv), the peer as a runtime
#   `a2a_agents.<node>` entry (its card's skills, 120s), the name in
#   `a2a.trusted_peers` and in the state roster `fleet.members` (the A2A
#   converge keeps trusted_peers the union of declared peers and the
#   roster), then a gateway restart.
# - `WORKSTATION_FLEET_PORT` (default 9902), `WORKSTATION_A2A_PORT`
#   (default 9900), `WORKSTATION_HERMES` (default ~/.local/bin/hermes).
set -u

port=${WORKSTATION_FLEET_PORT:-9902}
a2a_port=${WORKSTATION_A2A_PORT:-9900}
hermes=${WORKSTATION_HERMES:-$HOME/.local/bin/hermes}
state=$HOME/.local/state/workstation
roster=$state/fleet.members
lockdir=$state/fleet.lock
me=$(CDPATH='' cd -P "$(dirname "$0")" && pwd -P)/$(basename "$0")
# the service managers the gateway verbs drive live outside a service PATH
PATH=$PATH:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH

say() {
	printf 'workstation: fleet %s\n' "$*" >&2
}

label_ok() {
	printf '%s' "$1" | grep -Eqx '[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
}

self_status() {
	# self_status <jq field: name|uid|ip>
	tailscale status --json 2>/dev/null | jq -r --arg f "$1" '
		if $f == "name" then (.Self.DNSName // "" | split(".")[0])
		elif $f == "uid" then (.Self.UserID // "" | tostring)
		else ((.Self.TailscaleIPs // []) | map(select(test("^[0-9]+([.][0-9]+){3}$"))) | .[0] // "")
		end'
}

skills_json() {
	# skills_json <node> — the node's advertised skill ids (sanitized), JSON;
	# an unreachable card is the empty list
	out=$(curl -fsS --connect-timeout 2 --max-time 4 "http://$1:$a2a_port/.well-known/agent-card.json" 2>/dev/null |
		jq -c '[(.skills // [])[] | (.id // .name // empty) | tostring | select(test("^[A-Za-z0-9._-]{1,64}$"))] | unique' 2>/dev/null)
	if [ -n "$out" ]; then printf '%s' "$out"; else printf '[]'; fi
}

lock() {
	mkdir -p "$state"
	i=0
	until mkdir "$lockdir" 2>/dev/null; do
		# a holder killed mid-pairing leaves the directory: stale past 2 minutes
		if [ -n "$(find "$lockdir" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
			rmdir "$lockdir" 2>/dev/null
			continue
		fi
		i=$((i + 1))
		[ "$i" -ge 60 ] && return 1
		sleep 1
	done
}

unlock() {
	rmdir "$lockdir" 2>/dev/null
}

hermes_cfg() {
	"$hermes" config "$@" </dev/null >/dev/null 2>&1
}

store_pair() {
	# store_pair <node> — the token arrives on stdin; the runtime peer
	# entry, the trusted set and the roster follow
	node=$1
	workstation-a2a-token set "$node" || return 1
	tokenenv=A2A_PEER_TOKEN_$(printf '%s' "$node" | tr 'a-z-' 'A-Z_')
	entry=$(jq -nc --arg url "http://$node:$a2a_port" --arg ref "\${$tokenenv}" --argjson caps "$(skills_json "$node")" \
		'{url: $url, timeout: 120, capabilities: $caps, auth: {type: "bearer", token: $ref}}')
	hermes_cfg set --force "a2a_agents.$node" "$entry" || return 1
	mkdir -p "$state"
	{
		[ -f "$roster" ] && cat "$roster"
		printf '%s\n' "$node"
	} | sort -u >"$roster.new" && mv "$roster.new" "$roster"
	trusted=$(
		{
			"$hermes" config get a2a.trusted_peers </dev/null 2>/dev/null | sed -n 's/^ *- *//p'
			cat "$roster"
		} | grep -Ex '[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?' | sort -u | jq -Rcs 'split("\n") | map(select(length > 0))'
	)
	hermes_cfg set --force a2a.trusted_peers "$trusted" || return 1
}

restart_gateway() {
	gw=$("$hermes" gateway list </dev/null 2>/dev/null | sed -n 's/.*(current).*PID \([0-9][0-9]*\).*/\1/p' | head -n 1)
	if [ -z "$gw" ]; then
		say 'the gateway is not running; its next start serves the pairing'
	elif "$hermes" gateway restart </dev/null >/dev/null 2>&1; then
		say 'gateway restarted'
	else
		say 'gateway restart failed; run: hermes gateway restart'
	fi
}

respond() {
	# respond <status> <body>
	printf 'HTTP/1.0 %s\r\nContent-Type: text/plain\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
		"$1" "${#2}" "$2"
}

case ${1:-} in
handle)
	# one connection from socat: the caller's address is SOCAT_PEERADDR
	cr=$(printf '\r')
	read -r method path _ || exit 0
	while IFS= read -r line; do
		line=${line%"$cr"}
		[ -z "$line" ] && break
	done
	self=$(self_status name)
	case "$method $path" in
	"GET /fleet")
		respond '200 OK' "workstation-fleet v1 member=$self"
		;;
	"POST /join")
		peer_ip=${SOCAT_PEERADDR:-}
		who=$(tailscale whois --json "$peer_ip" 2>/dev/null)
		node=$(printf '%s' "$who" | jq -r '.Node.Name // "" | split(".")[0]' 2>/dev/null)
		uid=$(printf '%s' "$who" | jq -r '.Node.User // "" | tostring' 2>/dev/null)
		if [ -z "$node" ] || ! label_ok "$node" || [ "$node" = "$self" ]; then
			respond '403 Forbidden' 'not a tailnet node'
			say "join refused: $peer_ip is not a tailnet node"
			exit 0
		fi
		if [ "$uid" != "$(self_status uid)" ]; then
			respond '403 Forbidden' 'not this tailnet user'
			say "join refused: $node belongs to another tailscale user"
			exit 0
		fi
		if ! lock; then
			respond '503 Service Unavailable' 'busy'
			exit 0
		fi
		tok=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
		if printf '%s' "$tok" | store_pair "$node"; then
			unlock
			say "paired with $node"
			# socat ends this handler once the caller hangs up: the restart
			# runs detached, immune to that stop
			(
				trap '' TERM HUP PIPE
				restart_gateway
			) </dev/null >/dev/null &
			respond '200 OK' "member=$self
token=$tok"
		else
			unlock
			respond '500 Internal Server Error' 'pairing failed'
			say "pairing with $node failed"
		fi
		;;
	*)
		respond '404 Not Found' ''
		;;
	esac
	;;
serve)
	# the listener: bound to the tailnet IPv4 only; waits for the tailnet.
	# A stop (TERM/INT) takes the listener down with the loop.
	sp=''
	trap 'if [ -n "$sp" ]; then kill "$sp" 2>/dev/null; fi; exit 0' TERM INT
	while :; do
		ip=$(self_status ip)
		case $ip in
		[0-9]*.[0-9]*.[0-9]*.[0-9]*)
			say "serving on $ip:$port"
			socat "TCP-LISTEN:$port,bind=$ip,reuseaddr,fork" "EXEC:$me handle" &
			sp=$!
			wait "$sp" || say 'listener stopped'
			sp=''
			;;
		*) say 'waiting for the tailnet' ;;
		esac
		sleep 10 &
		wait $!
	done
	;;
join)
	# pair with every member on the tailnet that belongs to this user
	self=$(self_status name)
	uid=$(self_status uid)
	[ -n "$self" ] || {
		say 'the tailnet is unavailable (tailscaled down or logged out)'
		exit 1
	}
	members=$(tailscale status --json 2>/dev/null | jq -r --arg uid "$uid" '
		(.Peer // {})[] | select(.Online) | select((.UserID | tostring) == $uid)
		| ((.TailscaleIPs // []) | map(select(test("^[0-9]+([.][0-9]+){3}$"))) | .[0] // empty)')
	found=0
	paired=0
	for ip in $members; do
		marker=$(curl -fsS --connect-timeout 2 --max-time 4 "http://$ip:$port/fleet" 2>/dev/null) || continue
		node=${marker##*member=}
		case $marker in "workstation-fleet v1 member="*) ;; *) continue ;; esac
		label_ok "$node" || continue
		found=$((found + 1))
		reply=$(curl -fsS --connect-timeout 2 --max-time 60 -X POST "http://$ip:$port/join" 2>/dev/null) || {
			say "$node refused or failed the join"
			continue
		}
		tok=${reply##*token=}
		case $reply in "member=$node"*) ;; *)
			say "$node answered for another node"
			continue
			;;
		esac
		if printf '%s' "$tok" | store_pair "$node"; then
			paired=$((paired + 1))
			say "paired with $node"
		else
			say "storing the pairing with $node failed"
		fi
	done
	if [ "$found" = 0 ]; then
		say 'no fleet member answered on the tailnet — start the fleet on a converged machine first (workstation fleet)'
		exit 1
	fi
	[ "$paired" -gt 0 ] && restart_gateway
	say "joined: $paired of $found member(s) paired"
	[ "$paired" = "$found" ]
	;;
status)
	printf 'node: %s\n' "$(self_status name)"
	if [ -s "$roster" ]; then sed 's/^/member: /' "$roster"; else printf 'members: none\n'; fi
	;;
online)
	# the tailnet is up and this node is logged in
	tailscale status --json 2>/dev/null | jq -e '.BackendState == "Running"' >/dev/null
	;;
login)
	# the operator's own login: tailscale prints (or opens) its auth URL
	case $(uname -s) in
	Darwin) tailscale up ;;
	*)
		if [ "$(id -u)" = 0 ]; then
			tailscale up
		else
			sudo tailscale up
		fi
		;;
	esac
	;;
*)
	printf 'usage: workstation-fleet serve|join|status|online|login\n' >&2
	exit 2
	;;
esac
