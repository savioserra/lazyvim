#!/bin/sh
# Managed by the workstation substrate — the agent capability's A2A peer
# setup (`workstation peers`).
#
#   workstation-peers <peers.nix>
#
# | Screen | Contract |
# | --- | --- |
# | scan | the tailnet's online linux/macOS/windows nodes, each probed for an Agent Card (`:<port>/.well-known/agent-card.json`) and a pairing offer (`:<pair port>/offer`) |
# | offers | each node offering to pair with this one: Accept stores the pair's token and adds the node |
# | hub | one menu: every peer and every answering agent as a status row; Enter adds (all advertised skills, 120s) or opens the peer: Pair, Capabilities, Timeout, Remove |
# | save | `<peers.nix>` rewritten whole (nixfmt-clean, one rename); removed peers' tokens dropped |
#
# Pairing — one token per node pair, the same value on both ends:
#
# | Key in `~/.hermes/.env` | Holds |
# | --- | --- |
# | `A2A_PEER_TOKEN_<NODE>` | the token this node presents when calling `<node>` |
# | `A2A_PEER_TOKENS` row `<node>:<token>` | the token `<node>` presents when calling here |
#
# - Over the tailnet: this node opens a one-shot offer on its tailnet IPv4
#   (`<pair port>`, default `<port> + 1`) that answers only the peer's
#   tailnet IPv4 and serves the token once; `workstation peers` on the
#   peer finds the offer and accepts. The window is 90 seconds.
# - By hand (any A2A agent): paste the peer's token, or leave it blank to
#   generate one — printed once at exit.
# - Values travel only through the environment into hermes' own .env
#   writer: never argv, never a file, never a log line. Pairings store at
#   once and leave the restart marker the next apply's converge consumes.
# - Remote fields are untrusted: node names pass the DNS-label grammar,
#   skill ids pass `[A-Za-z0-9._-]`; nothing else reaches the file.
#
# Exit: 0 nothing to apply, 10 saved (apply serves it), 1 failure, 2 usage.
set -u

# --- the pairing handler: one tailnet connection, run by socat ----------------
if [ "${1:-}" = --pair-handler ]; then
	cr=$(printf '\r')
	read -r _ path _ || exit 0
	while IFS= read -r line; do
		line=${line%"$cr"}
		[ -z "$line" ] && break
	done
	status='200 OK'
	body=''
	case $path in
	/offer) body="workstation-pair v1 from=$WS_PAIR_FROM to=$WS_PAIR_TO" ;;
	/token)
		if [ -e "$WS_PAIR_DONE" ]; then status='410 Gone'; else body=$WS_PAIR_TOKEN; fi
		;;
	*) status='404 Not Found' ;;
	esac
	printf 'HTTP/1.0 %s\r\nContent-Type: text/plain\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
		"$status" "${#body}" "$body"
	if [ "$path" = /token ] && [ "$status" = '200 OK' ]; then
		: >"$WS_PAIR_DONE"
	fi
	exit 0
fi

file=${1:?usage: workstation-peers <peers.nix>}
port=${WORKSTATION_A2A_PORT:-9900}
case $port in
'' | *[!0-9]*) printf 'workstation: peers — WORKSTATION_A2A_PORT must be a number\n' >&2 && exit 2 ;;
esac
pair_port=${WORKSTATION_A2A_PAIR_PORT:-$((port + 1))}
case $pair_port in
'' | *[!0-9]*) printf 'workstation: peers — WORKSTATION_A2A_PAIR_PORT must be a number\n' >&2 && exit 2 ;;
esac
window=90
env_file=$HOME/.hermes/.env
marker=$HOME/.local/state/workstation/hermes-a2a.restart
python=$HOME/.local/opt/hermes/python/bin/python3
checkout=${HERMES_ENGINE_CHECKOUT:-$HOME/.hermes/hermes-agent}
me=$(CDPATH='' cd -P "$(dirname "$0")" && pwd -P)/$(basename "$0")
[ -f "$file" ] || {
	printf 'workstation: peers — %s missing (unexpected tree)\n' "$file" >&2
	exit 1
}
if [ ! -t 0 ] || [ ! -t 1 ]; then
	printf 'workstation: peers — the dialogs need a terminal\n' >&2
	exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/ws-peers.XXXXXX") || exit 1
listener=''
# the exit path: the pairing listener stops, the work tree goes
trap 'if [ -n "$listener" ]; then kill "$listener" 2>/dev/null; fi; rm -rf "$work"' EXIT
trap 'exit 1' INT TERM
mkdir -p "$work/p"

# --- dialog geometry: the terminal's, clamped ---------------------------------
size=$(stty size 2>/dev/null || printf '24 80')
W=$((${size#* } - 8))
[ "$W" -gt 96 ] && W=96
[ "$W" -lt 60 ] && W=60
H=$((${size% *} - 4))
[ "$H" -gt 30 ] && H=30
[ "$H" -lt 16 ] && H=16

# --- helpers -------------------------------------------------------------------
label_ok() {
	printf '%s' "$1" | grep -Eqx '[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
}

token_env() {
	printf 'A2A_PEER_TOKEN_%s' "$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"
}

paired() {
	# presence only — the value is never read
	[ -f "$env_file" ] && grep -Eq "^(export )?$(token_env "$1")=.+" "$env_file"
}

token_ok() {
	case $1 in
	*[!A-Za-z0-9._~+/=-]*) return 1 ;;
	esac
	[ "${#1}" -ge 16 ] && [ "${#1}" -le 512 ]
}

gen_token() {
	od -An -tx1 -N32 /dev/urandom | tr -d ' \n'
}

wt() {
	# one dialog; a result (menu tag, input) comes back on stdout
	whiptail --title ' workstation peers ' --backtitle "$backtitle" "$@" 3>&1 1>&2 2>&3
}

if [ -x "$python" ] && [ -f "$checkout/hermes_cli/main.py" ]; then
	hermes_ready=1
else
	hermes_ready=0
fi

# hermes' own .env writer on the pinned interpreter: the value arrives in
# WS_VALUE. hermes_bootstrap re-executes the interpreter into the runtime's
# environment (same pid), so the value leaves os.environ right after that
# import and before any hermes_cli import; a failure names its class only
# (a message could carry the value)
writer='import os, sys
sys.dont_write_bytecode = True
os.environ.pop("PYTHONHOME", None)
os.environ.pop("PYTHONPATH", None)
sys.path.insert(0, os.environ["HERMES_ENGINE_CHECKOUT"])
try:
    import hermes_bootstrap  # noqa: F401
    value = os.environ.pop("WS_VALUE", "")
    from hermes_cli.config import get_env_value_prefer_dotenv, remove_env_value, require_env_writable, save_env_value
    node, key, op = os.environ["WS_NODE"], os.environ["WS_KEY"], os.environ["WS_OP"]
    if op == "set" and not value:
        raise ValueError("no token value")
    for k in (key, "A2A_PEER_TOKENS"):
        require_env_writable(k, "set")
    rows = [r.strip() for r in (get_env_value_prefer_dotenv("A2A_PEER_TOKENS") or "").split(",") if r.strip()]
    rows = [r for r in rows if r.split(":", 1)[0].strip() != node]
    if op == "set":
        save_env_value(key, value)
        rows.append(node + ":" + value)
    else:
        remove_env_value(key)
    if rows:
        save_env_value("A2A_PEER_TOKENS", ",".join(rows))
    else:
        remove_env_value("A2A_PEER_TOKENS")
except Exception as exc:
    print("token write failed (" + type(exc).__name__ + ")", file=sys.stderr)
    sys.exit(1)
'

# the data root's first bootstrap installs dependencies (subprocesses):
# the root is prepared once, by a secret-free call, before the first write
prepared=0
prepare_hermes() {
	[ "$prepared" = 1 ] && return 0
	HERMES_HOME=$HOME/.hermes HERMES_ENGINE_CHECKOUT=$checkout "$python" -I -c 'import os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ["HERMES_ENGINE_CHECKOUT"])
import hermes_bootstrap  # noqa: F401
from hermes_cli.config import save_env_value  # noqa: F401
' </dev/null >/dev/null 2>"$work/writer.err" || return 1
	prepared=1
}

tokens_changed=0
write_token() {
	# write_token <node> <set|drop> [<value>] — a function argument, never a
	# process argument: the value reaches python through the environment
	prepare_hermes || return 1
	if (
		WS_NODE=$1
		WS_OP=$2
		WS_KEY=$(token_env "$1")
		HERMES_HOME=$HOME/.hermes
		HERMES_ENGINE_CHECKOUT=$checkout
		export WS_NODE WS_OP WS_KEY HERMES_HOME HERMES_ENGINE_CHECKOUT
		if [ "$2" = set ]; then
			WS_VALUE=$3
			export WS_VALUE
		fi
		exec "$python" -I -c "$writer"
	) </dev/null >/dev/null 2>"$work/writer.err"; then
		tokens_changed=1
		mkdir -p "${marker%/*}" && : >"$marker"
		return 0
	fi
	return 1
}

# --- the peers state: one directory per peer -----------------------------------
# p/<node>/{url,timeout,caps}; a peer exists iff its directory does
if ! nix --extra-experimental-features nix-command eval --json --file "$file" >"$work/configured.json" 2>"$work/err"; then
	printf 'workstation: peers — %s does not evaluate: %s\n' "$file" "$(tail -n 1 "$work/err")" >&2
	exit 1
fi
for node in $(jq -r 'keys[]' "$work/configured.json"); do
	label_ok "$node" || continue
	NODE=$node
	export NODE
	mkdir -p "$work/p/$node"
	url=$(jq -r '.[env.NODE].url' "$work/configured.json")
	# the url re-renders into a nix string: only the option's own grammar
	printf '%s' "$url" | grep -Eqx 'https?://[A-Za-z0-9.-]+(:[0-9]+)?/?' || url="http://$node:$port"
	printf '%s\n' "$url" >"$work/p/$node/url"
	jq -r '.[env.NODE].timeout // 120' "$work/configured.json" >"$work/p/$node/timeout"
	jq -r '(.[env.NODE].capabilities // [])[]' "$work/configured.json" |
		grep -Ex '[A-Za-z0-9._-]{1,64}' >"$work/p/$node/caps" || true
done

render() {
	printf "# This machine's A2A peers — written by workstation peers.\n"
	printf '# Local edit — keep it uncommitted (the committed copy is the empty template).\n'
	set -- "$work"/p/*
	if [ ! -d "$1" ]; then
		printf '{ }\n'
		return 0
	fi
	printf '{\n'
	for dir do
		node=${dir##*/}
		printf '  %s = {\n' "$node"
		printf '    url = "%s";\n' "$(cat "$work/p/$node/url")"
		printf '    timeout = %s;\n' "$(cat "$work/p/$node/timeout")"
		caps=$(cat "$work/p/$node/caps")
		case $(grep -c . "$work/p/$node/caps") in
		0) printf '    capabilities = [ ];\n' ;;
		1) printf '    capabilities = [ "%s" ];\n' "$caps" ;;
		*)
			printf '    capabilities = [\n'
			for cap in $caps; do printf '      "%s"\n' "$cap"; done
			printf '    ];\n'
			;;
		esac
		printf '  };\n'
	done
	printf '}\n'
}
render >"$work/original.nix"

skills_of() {
	# skills_of <node> — the card's advertised skill ids, sanitized
	[ -f "$work/card.$1" ] || return 0
	jq -r '(.skills // [])[] | (.id // .name // empty) | tostring' "$work/card.$1" |
		grep -Ex '[A-Za-z0-9._-]{1,64}' | sort -u
}

# --- scan: cards and pairing offers ---------------------------------------------
self=''
self_ip=''
scan() {
	wt --infobox "Scanning the tailnet for A2A agents (port $port)..." 7 "$W"
	rm -f "$work"/card.* "$work"/offer.* "$work"/raw.*
	if ! tailscale status --json >"$work/status.json" 2>/dev/null; then
		return 1
	fi
	self=$(jq -r '.Self.DNSName // "" | split(".")[0]' "$work/status.json")
	self_ip=$(jq -r '(.Self.TailscaleIPs // []) | map(select(test("^[0-9]+([.][0-9]+){3}$"))) | .[0] // ""' "$work/status.json")
	# the candidates: online machines that can run an agent (phones and
	# tablets are not offered), as "<node> <ipv4>"
	jq -r '(.Peer // {})[] | select(.Online) | select(.OS == "linux" or .OS == "macOS" or .OS == "windows")
		| [(.DNSName | split(".")[0]), ((.TailscaleIPs // []) | map(select(test("^[0-9]+([.][0-9]+){3}$"))) | .[0] // "")]
		| @tsv' "$work/status.json" | sort -u >"$work/online.raw"
	: >"$work/online"
	while IFS="$(printf '\t')" read -r node ip; do
		label_ok "$node" && printf '%s %s\n' "$node" "$ip" >>"$work/online"
	done <"$work/online.raw"
	while read -r node ip; do
		(
			if curl -fsS --connect-timeout 2 --max-time 4 \
				"http://$node:$port/.well-known/agent-card.json" -o "$work/raw.$node" 2>/dev/null &&
				jq -e 'type == "object" and (.name | type == "string")' "$work/raw.$node" >/dev/null 2>&1; then
				mv "$work/raw.$node" "$work/card.$node"
			fi
			if [ -n "$ip" ] && [ -n "$self" ]; then
				offer=$(curl -fsS --connect-timeout 1 --max-time 2 "http://$ip:$pair_port/offer" 2>/dev/null)
				[ "$offer" = "workstation-pair v1 from=$node to=$self" ] && printf '%s\n' "$ip" >"$work/offer.$node"
			fi
		) &
	done <"$work/online"
	wait
	backtitle="workstation peers  |  this node: ${self:-?}  |  A2A port $port"
	return 0
}

ip_of() {
	sed -n "s/^$1 //p" "$work/online" | head -n 1
}

add_peer() {
	# add_peer <node> — the smart defaults: every advertised skill, 120s
	mkdir -p "$work/p/$1"
	printf 'http://%s:%s\n' "$1" "$port" >"$work/p/$1/url"
	printf '120\n' >"$work/p/$1/timeout"
	skills_of "$1" >"$work/p/$1/caps"
}

# --- pairing -----------------------------------------------------------------
generated=''
needs_hermes() {
	[ "$hermes_ready" = 1 ] && return 0
	wt --msgbox "Pairing stores the token through hermes, which this machine gets with its first switch.\n\nRun: workstation apply, then workstation peers again." 11 "$W"
	return 1
}

accept_offer() {
	# accept_offer <node> — fetch the offered token once and store it
	ip=$(cat "$work/offer.$1")
	tok=$(curl -fsS --connect-timeout 2 --max-time 4 "http://$ip:$pair_port/token" 2>/dev/null)
	case $tok in
	*[!0-9a-f]*) tok='' ;;
	esac
	if [ "${#tok}" -ne 64 ]; then
		wt --msgbox "The pairing offer from $1 closed before the token arrived.\n\nStart it again on $1: workstation peers, select $self, Pair." 11 "$W"
		return 1
	fi
	if ! write_token "$1" set "$tok"; then
		wt --msgbox "Storing the token failed: $(cat "$work/writer.err")" 9 "$W"
		return 1
	fi
	[ -d "$work/p/$1" ] || add_peer "$1"
	wt --msgbox "Paired with $1." 7 "$W"
}

offer_pairing() {
	# offer_pairing <node> — the one-shot offer, answered only to the
	# peer's tailnet IPv4; the token travels in socat's environment
	peer_ip=$(ip_of "$1")
	if [ -z "$peer_ip" ] || [ -z "$self_ip" ]; then
		wt --msgbox "$1 is not online on the tailnet. Pair when both machines are up, or enter a token by hand." 9 "$W"
		return 1
	fi
	tok=$(gen_token)
	rm -f "$work/pair.done"
	WS_PAIR_TOKEN=$tok WS_PAIR_FROM=$self WS_PAIR_TO=$1 WS_PAIR_DONE=$work/pair.done \
		socat -T 10 "TCP-LISTEN:$pair_port,bind=$self_ip,reuseaddr,fork,range=$peer_ip/32" \
		"EXEC:$me --pair-handler" 2>"$work/socat.err" &
	listener=$!
	sleep 1
	if ! kill -0 "$listener" 2>/dev/null; then
		listener=''
		wt --msgbox "The pairing port $pair_port did not open on $self_ip: $(tail -n 1 "$work/socat.err")" 9 "$W"
		return 1
	fi
	i=0
	while [ "$i" -lt "$window" ]; do
		[ -e "$work/pair.done" ] && break
		printf '%s\n' "$(((window - i) * 100 / window))"
		sleep 1
		i=$((i + 1))
	done | whiptail --title ' workstation peers ' --backtitle "$backtitle" --gauge \
		"Waiting for $1 to accept (${window}s)...\n\nOn $1 run:  workstation peers\nIt finds this offer and asks to accept." 11 "$W" 100
	sleep 1
	kill "$listener" 2>/dev/null
	wait "$listener" 2>/dev/null
	listener=''
	if [ ! -e "$work/pair.done" ]; then
		wt --msgbox "$1 did not accept within ${window}s.\n\nRun workstation peers on $1 while this one waits." 10 "$W"
		return 1
	fi
	if ! write_token "$1" set "$tok"; then
		wt --msgbox "Storing the token failed: $(cat "$work/writer.err")" 9 "$W"
		return 1
	fi
	wt --msgbox "Paired with $1." 7 "$W"
}

pair_by_hand() {
	while :; do
		tok=$(wt --passwordbox "$1 - its token for this pair.\n\nPaste the token the other agent uses, or leave blank to generate one (printed once at exit, for entry on $1)." 12 "$W") || return 1
		if [ -z "$tok" ]; then
			tok=$(gen_token)
			generated="$generated $1"
			eval "gen_$(printf '%s' "$1" | tr '-' '_')=\$tok"
			break
		fi
		token_ok "$tok" && break
		wt --msgbox 'A token is 16 to 512 characters of A-Z a-z 0-9 . _ ~ + / = -' 8 "$W"
	done
	if ! write_token "$1" set "$tok"; then
		wt --msgbox "Storing the token failed: $(cat "$work/writer.err")" 9 "$W"
		return 1
	fi
	wt --msgbox "Token stored for $1." 7 "$W"
}

pair() {
	needs_hermes || return 0
	how=$(wt --ok-button Select --cancel-button Back --notags --menu \
		"Pair $self with $1: both agents then call each other with one shared token." 12 "$W" 3 \
		tailnet "Pair over the tailnet (run workstation peers on $1 too)" \
		hand "Enter or generate a token by hand (any A2A agent)") || return 0
	case $how in
	tailnet) offer_pairing "$1" ;;
	hand) pair_by_hand "$1" ;;
	esac
}

# --- the peer screens ------------------------------------------------------------
edit_caps() {
	skills_of "$1" >"$work/advertised"
	sort -u "$work/advertised" "$work/p/$1/caps" >"$work/offered"
	if [ ! -s "$work/offered" ]; then
		wt --msgbox "$1 advertises no skills (or its card is not answering)." 8 "$W"
		return 0
	fi
	set --
	while read -r skill; do
		if grep -Fqx "$skill" "$work/p/$1/caps"; then on=ON; else on=OFF; fi
		set -- "$@" "$skill" '' "$on"
	done <"$work/offered"
	rows=$(($# / 3))
	[ "$rows" -gt $((H - 9)) ] && rows=$((H - 9))
	picked=$(wt --separate-output --checklist \
		"$1 - the capabilities a2a_orchestrate routes to it:" $((rows + 9)) "$W" "$rows" "$@") || return 0
	printf '%s\n' "$picked" | grep -Ex '[A-Za-z0-9._-]{1,64}' >"$work/p/$1/caps" || true
}

edit_timeout() {
	t=$(cat "$work/p/$1/timeout")
	while :; do
		t=$(wt --inputbox "$1 - call timeout in seconds (1-3600):" 9 "$W" "$t") || return 0
		case $t in
		'' | *[!0-9]*) ;;
		*) if [ "$t" -ge 1 ] && [ "$t" -le 3600 ]; then
			printf '%s\n' "$t" >"$work/p/$1/timeout"
			return 0
		fi ;;
		esac
	done
}

dropped=''
peer_screen() {
	node=$1
	while [ -d "$work/p/$node" ]; do
		if paired "$node"; then pstate='paired'; dflt=back; else pstate='not paired'; dflt=pair; fi
		[ "$hermes_ready" = 1 ] || pstate='pairs after the first switch'
		if [ -f "$work/card.$node" ]; then reach='answering'; else reach='not answering'; fi
		choice=$(wt --ok-button Select --cancel-button Back --notags --default-item "$dflt" --menu \
			"$node  ($reach)\n$(cat "$work/p/$node/url")" 15 "$W" 5 \
			pair "Pair                ($pstate)" \
			caps "Capabilities        ($(grep -c . "$work/p/$node/caps") selected)" \
			timeout "Timeout             ($(cat "$work/p/$node/timeout")s)" \
			remove "Remove this peer" \
			back "Back") || return 0
		case $choice in
		pair) pair "$node" ;;
		caps) edit_caps "$node" ;;
		timeout) edit_timeout "$node" ;;
		remove)
			if wt --yes-button Remove --no-button Keep --yesno \
				"Remove $node from the peers?\n\nOn save its stored token goes too." 10 "$W"; then
				rm -rf "${work:?}/p/$node"
				dropped="$dropped $node"
			fi
			;;
		*) return 0 ;;
		esac
	done
}

# --- the run ---------------------------------------------------------------------
backtitle='workstation peers'
if ! scan; then
	printf 'workstation: peers — the tailnet is unavailable (tailscaled down or logged out); run: workstation peers (once it is up)\n' >&2
	exit 1
fi

handle_offers() {
	for offer in "$work"/offer.*; do
		[ -f "$offer" ] || continue
		node=${offer##*/offer.}
		needs_hermes || return 0
		if wt --yes-button Accept --no-button Ignore --yesno \
			"$node wants to pair with $self.\n\nAccept? Both agents then call each other with one shared token." 10 "$W"; then
			accept_offer "$node"
		fi
	done
}
handle_offers

while :; do
	{
		for dir in "$work"/p/*; do
			[ -d "$dir" ] && printf '%s\n' "${dir##*/}"
		done
		for card in "$work"/card.*; do
			[ -f "$card" ] && printf '%s\n' "${card##*/card.}"
		done
	} | sort -u >"$work/listed"
	set --
	while read -r node; do
		if [ -d "$work/p/$node" ]; then
			if paired "$node"; then pstate='paired'; else pstate='not paired'; fi
			if [ -f "$work/card.$node" ]; then reach=''; else reach='  (not answering)'; fi
			row="[x] peer   $(grep -c . "$work/p/$node/caps") caps  $(cat "$work/p/$node/timeout")s  $pstate$reach"
		else
			name=$(jq -r '.name' "$work/card.$node" | LC_ALL=C tr -cd '[:alnum:] ._()-' | cut -c1-32)
			row="[ ] add    $name"
		fi
		set -- "$@" "$node" "$row"
	done <"$work/listed"
	set -- "$@" '[rescan]' 'Rescan the tailnet (agents + pairing offers)' \
		'[save]' 'Save and exit' '[discard]' 'Discard changes and exit'
	# the online nodes with no agent: named, so a missing row explains itself
	noagent=''
	while read -r node _; do
		[ -f "$work/card.$node" ] || noagent="$noagent $node"
	done <"$work/online"
	text="Peers this agent calls. Enter adds an agent or opens a peer."
	[ -n "$noagent" ] && text="$text\nNo agent on :$port:$(printf '%s' "$noagent" | cut -c1-$((W - 20)))"
	rows=$(($# / 2))
	[ "$rows" -gt $((H - 9)) ] && rows=$((H - 9))
	choice=$(wt --ok-button Select --cancel-button Discard --default-item '[save]' --menu \
		"$text" "$H" "$W" "$rows" "$@") || choice='[discard]'
	case $choice in
	'[rescan]')
		scan || wt --msgbox 'The tailnet is unavailable.' 7 "$W"
		handle_offers
		;;
	'[save]') break ;;
	'[discard]')
		render >"$work/now.nix"
		if cmp -s "$work/now.nix" "$work/original.nix" ||
			wt --yes-button Discard --no-button Back --yesno 'Discard the unsaved peer changes?' 8 "$W"; then
			printf 'workstation: peers — discarded; %s unchanged\n' "$file"
			[ "$tokens_changed" = 1 ] && printf 'workstation: the pairings made this run are stored — next: workstation apply\n' && exit 10
			exit 0
		fi
		;;
	*)
		# only a listed row (the menu's own tags)
		grep -Fqx -- "$choice" "$work/listed" || continue
		label_ok "$choice" || continue
		if [ -d "$work/p/$choice" ]; then
			peer_screen "$choice"
		else
			add_peer "$choice"
			if [ "$hermes_ready" = 1 ] && ! paired "$choice" &&
				wt --yes-button Pair --no-button Later --yesno \
					"Added $choice ($(grep -c . "$work/p/$choice/caps") capabilities, 120s).\n\nPair now? Both agents then call each other with one shared token." 11 "$W"; then
				pair "$choice"
			fi
		fi
		;;
	esac
done

# --- save -----------------------------------------------------------------------
render >"$work/peers.nix"
saved=0
if ! cmp -s "$work/peers.nix" "$file"; then
	if ! { cp "$work/peers.nix" "$file.new.$$" && mv "$file.new.$$" "$file"; }; then
		rm -f "$file.new.$$"
		printf 'workstation: peers — could not write %s\n' "$file" >&2
		exit 1
	fi
	saved=1
	printf 'workstation: peers saved in %s\n' "$file"
fi
failed=0
for node in $dropped; do
	[ -d "$work/p/$node" ] && continue
	paired "$node" || continue
	if write_token "$node" drop; then
		printf '  %s — removed; its token dropped\n' "$node"
	else
		printf '  %s — removed; dropping its token failed (re-run: workstation peers)\n' "$node"
		failed=1
	fi
done
for dir in "$work"/p/*; do
	[ -d "$dir" ] || continue
	node=${dir##*/}
	if paired "$node"; then pstate='paired'; else pstate='not paired'; fi
	printf '  %s -> %s  %s\n' "$node" "$(cat "$work/p/$node/url")" "$pstate"
done
if [ -n "$generated" ]; then
	printf '\nGenerated tokens - enter each on the named agent:\n'
	for node in $generated; do
		eval "tok=\${gen_$(printf '%s' "$node" | tr '-' '_')}"
		printf '  %s: %s\n' "$node" "$tok"
	done
	printf '\n'
fi
[ "$failed" = 1 ] && exit 1
if [ "$saved" = 1 ] || [ "$tokens_changed" = 1 ]; then
	printf 'workstation: next — workstation apply\n'
	exit 10
fi
printf 'workstation: peers unchanged\n'
exit 0
