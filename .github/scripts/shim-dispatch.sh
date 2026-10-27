#!/bin/sh
# The launcher shim's dispatch gate: bin/workstation is the whole client
# (reads are nix evals, writes delegate to the staged workstation-switch
# driver), so the contract lives in its verb dispatch. Each step runs the
# REAL repo shim against a stub `nix` on a private PATH — the stub records
# the eval target and answers a fixed JSON body, so the gate proves the
# dispatch and the flake resolution without a nix installation.
#
# Contract asserted:
#   1. help and the bare verb exit 0 printing usage; an unknown verb and
#      an unknown option exit 2.
#   2. a read verb evals exactly #workstation.report.<verb> against the
#      resolved flake and prints the eval's stdout unchanged.
#   3. flake resolution order: --flake PATH > $WORKSTATION_FLAKE > the
#      first flake.nix walking up from $PWD > the staged generation
#      snapshot (~/.local/opt/workstation/flake); with none of the four
#      the read fails closed with the fix named.
#   4. a write verb delegates to the workstation-switch driver when one is
#      on PATH (the stub receives the verb), and fails closed naming the
#      missing driver when none is.
set -eu
progname='shim-dispatch.sh'
repo_root=$(CDPATH='' cd -P "$(dirname "$0")/../.." && pwd -P)
shim=$repo_root/bin/workstation
[ -f "$shim" ] || { echo "$progname: the shim is missing at bin/workstation" >&2; exit 1; }

root=$(mktemp -d "${TMPDIR:-/tmp}/shim-dispatch.XXXXXX")
trap 'rm -rf "$root"' EXIT
stub_dir=$root/stub
mkdir -p "$stub_dir"
: > "$root/stub.log"

# the stub nix: log the full argument vector, emit a fixed JSON body
{
	printf '#!/bin/sh\n'
	printf 'printf "%%s\\n" "$*" >> %s\n' "'$root/stub.log'"
	printf "printf '%s\\n' '{\"stub\":true}'\n" '{"stub":true}'
} > "$stub_dir/nix"
chmod +x "$stub_dir/nix"

# the stub switch driver: log the invocation
{
	printf '#!/bin/sh\n'
	printf 'printf "%%s\\n" "$*" >> %s\n' "'$root/stub.log'"
} > "$stub_dir/workstation-switch"
chmod +x "$stub_dir/workstation-switch"

fail() { echo "$progname: FAIL: $*" >&2; exit 1; }
expect_log() {
	grep -Fq "$1" "$root/stub.log" || fail "expected stub log line '$1' (got: $(tail -1 "$root/stub.log"))"
}

PATH=$stub_dir:/usr/bin:/bin
export PATH
unset WORKSTATION_FLAKE

# 1. the help contract
out=$("$shim" help) || fail 'help must exit 0'
printf '%s' "$out" | grep -q 'workstation.report' || fail 'usage must name the read surface'
out=$("$shim") || fail 'the bare verb must exit 0 (usage, never a blind TUI)'
printf '%s' "$out" | grep -q 'SYNOPSIS\|workstation —' || fail 'the bare verb prints usage'
rc=0
"$shim" frobnicate >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] && fail 'an unknown verb must fail'
[ "$rc" = 2 ] || fail "unknown verb must exit 2 (got $rc)"
rc=0
"$shim" --bogus >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "unknown option must exit 2 (got $rc)"

# 2. reads eval the report verbs; the flake lands in the eval target
out=$("$shim" --flake "$repo_root" status) || fail 'status with an explicit flake failed'
[ "$out" = '{"stub":true}' ] || fail 'the read must print the eval stdout unchanged'
expect_log "eval --json $repo_root#workstation.report.status"

# 3. the resolution order
out=$(WORKSTATION_FLAKE=$repo_root "$shim" plan) || fail 'status via WORKSTATION_FLAKE failed'
expect_log "$repo_root#workstation.report.plan"
out=$(cd "$repo_root/docs" && "$shim" capabilities) || fail 'status via the checkout walk failed'
expect_log "$repo_root#workstation.report.capabilities"
mkdir -p "$root/home/.local/opt/workstation"
printf 'flake.snapshot\n' > "$root/home/.local/opt/workstation/flake"
out=$(cd "$root/home" && HOME=$root/home "$shim" status) || fail 'status via the staged snapshot failed'
expect_log "$root/home/.local/opt/workstation/flake#workstation.report.status"
out=$(cd "$root" && HOME=$root/bare "$shim" status 2>"$root/err") && fail 'a bare host read must fail closed'
grep -q 'no flake to read' "$root/err" || fail 'the bare-host failure must name the fix'

# scope: `capabilities editor` appends the attrpath element
out=$(cd "$repo_root" && "$shim" capabilities editor) || fail 'a scoped read failed'
expect_log "$repo_root#workstation.report.capabilities.editor"
"$shim" capabilities 'bad;name' >/dev/null 2>&1 && fail 'a scope element must be a plain attribute name'

# 3b. the identity gate: writes refuse the uncaptured template
# (the test owns its template fixture — the live checkout's identity may
# legitimately be captured on a converged host)
template=$root/templateflake
mkdir -p "$template/hosts"
printf '{ host = "TEMPLATE"; user = "TEMPLATE"; home = "/home/TEMPLATE"; tailscaleFqdn = ""; }\n' >"$template/hosts/identity.nix"
rc=0
WORKSTATION_FLAKE=$template "$shim" apply 2>"$root/err" || rc=$?
[ "$rc" = 2 ] || fail 'apply must refuse the uncaptured template identity with exit 2'
grep -q 'workstation init' "$root/err" || fail 'the refusal must name workstation init'

# 3c. a captured identity lets writes delegate
fixture=$root/fakeflake
mkdir -p "$fixture/hosts"
printf '{ host = "testhost"; user = "testuser"; home = "/home/testuser"; tailscaleFqdn = ""; }\n' >"$fixture/hosts/identity.nix"

# 4. writes delegate to the staged driver; absence fails closed
WORKSTATION_FLAKE=$fixture "$shim" apply >/dev/null 2>&1 || fail 'apply must delegate to the staged driver'
expect_log 'apply'
WORKSTATION_FLAKE=$fixture "$shim" rollback --system >/dev/null 2>&1 || fail 'rollback --system must delegate'
expect_log 'rollback --system'
mv "$stub_dir/workstation-switch" "$stub_dir/workstation-switch.bak"
WORKSTATION_FLAKE=$fixture "$shim" apply >/dev/null 2>&1 && fail 'apply without a driver must fail'
grep -q 'workstation-switch' "$root/err" 2>/dev/null ||
	{ WORKSTATION_FLAKE=$fixture "$shim" apply 2>"$root/err" || true; grep -q 'workstation-switch' "$root/err" || fail 'the missing-driver failure must name the driver'; }

echo "$progname: OK (dispatch, resolution order, delegation and fail-closed paths all hold)"
