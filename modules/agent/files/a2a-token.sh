#!/bin/sh
# Managed by the workstation substrate — the agent capability's pair-token
# store (the A2A peer tokens in ~/.hermes/.env).
#
#   printf '%s' "$token" | workstation-a2a-token set <node>
#   workstation-a2a-token drop <node>
#
# | Key | Holds |
# | --- | --- |
# | `A2A_PEER_TOKEN_<NODE>` | the token this node presents when calling `<node>` |
# | `A2A_PEER_TOKENS` row `<node>:<token>` | the token `<node>` presents when calling here |
#
# - The value arrives on stdin and reaches hermes' own .env writer through
#   the environment: never argv, a file or a log line.
# - hermes_bootstrap re-executes the interpreter (same pid): the value
#   leaves os.environ right after that import, before any hermes_cli
#   import; a fresh data root is prepared first by a secret-free call.
# - A failure names its class only (a message could carry the value).
#
# Exit: 0 stored, 1 failed, 2 usage, 3 hermes not provisioned yet.
set -u

op=${1:-}
node=${2:-}
case $op in
set | drop) ;;
*)
	printf 'usage: workstation-a2a-token set|drop <node>\n' >&2
	exit 2
	;;
esac
if ! printf '%s' "$node" | grep -Eqx '[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'; then
	printf 'workstation-a2a-token: %s is not a node name (a DNS label)\n' "$node" >&2
	exit 2
fi
python=$HOME/.local/opt/hermes/python/bin/python3
checkout=${HERMES_ENGINE_CHECKOUT:-$HOME/.hermes/hermes-agent}
if [ ! -x "$python" ] || [ ! -f "$checkout/hermes_cli/main.py" ]; then
	printf 'workstation-a2a-token: hermes is not provisioned yet (run: workstation apply)\n' >&2
	exit 3
fi

WS_VALUE=''
if [ "$op" = set ]; then
	IFS= read -r WS_VALUE || [ -n "$WS_VALUE" ] || {
		printf 'workstation-a2a-token: no token on stdin\n' >&2
		exit 2
	}
	case $WS_VALUE in
	*[!A-Za-z0-9._~+/=-]*)
		printf 'workstation-a2a-token: the token carries characters outside A-Z a-z 0-9 . _ ~ + / = -\n' >&2
		exit 2
		;;
	esac
	if [ "${#WS_VALUE}" -lt 16 ] || [ "${#WS_VALUE}" -gt 512 ]; then
		printf 'workstation-a2a-token: a token is 16 to 512 characters\n' >&2
		exit 2
	fi
fi

HERMES_HOME=${HERMES_HOME:-$HOME/.hermes}
HERMES_ENGINE_CHECKOUT=$checkout
export HERMES_HOME HERMES_ENGINE_CHECKOUT

# the data root's first bootstrap installs dependencies: prepared once,
# secret-free, before the value enters any process environment
"$python" -I -c 'import os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ["HERMES_ENGINE_CHECKOUT"])
import hermes_bootstrap  # noqa: F401
from hermes_cli.config import save_env_value  # noqa: F401
' </dev/null >/dev/null 2>&1 || {
	printf 'workstation-a2a-token: preparing the hermes data root failed\n' >&2
	exit 1
}

WS_NODE=$node
WS_OP=$op
WS_KEY=A2A_PEER_TOKEN_$(printf '%s' "$node" | tr 'a-z-' 'A-Z_')
export WS_VALUE WS_NODE WS_OP WS_KEY
exec "$python" -I -c 'import os, sys
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
    print("workstation-a2a-token: write failed (" + type(exc).__name__ + ")", file=sys.stderr)
    sys.exit(1)
' </dev/null >/dev/null
