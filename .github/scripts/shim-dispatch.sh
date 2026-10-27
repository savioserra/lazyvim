#!/bin/sh
# The launcher shim's dispatch gate: bin/workstation is the whole client
# (reads are nix evals, writes delegate to the staged workstation-switch
# driver), so the contract lives in its verb dispatch. Each step runs the
# REAL repo shim against a stub `nix` on a private PATH — the stub records
# the eval target and answers from a fixed body (and, for the selection
# verbs, from the selections file the shim actually wrote), so the gate
# proves the dispatch and the flake resolution without a nix installation.
#
# Contract asserted:
#   1. help and the bare verb exit 0 printing usage; an unknown verb and
#      an unknown option exit 2.
#   2. a read verb evals exactly #workstation.report.<verb> against the
#      resolved flake and prints the eval's stdout unchanged; `selected`
#      reads #workstation.report.selections.
#   3. flake resolution order: --flake PATH > $WORKSTATION_FLAKE > the
#      first flake.nix walking up from $PWD > the staged generation
#      snapshot (~/.local/opt/workstation/flake); with none of the four
#      the read fails closed with the fix named.
#   4. a write verb delegates to the workstation-switch driver when one is
#      on PATH (the stub receives the verb), and fails closed naming the
#      missing driver when none is.
#   5. the selection verbs: add/remove validate the path grammar and the
#      walk-derived row before any write (baseline refuses, unknown paths
#      refuse, bad grammar refuses), edit hosts/selections.nix
#      canonically (dedup on add, the disable pin on removing a
#      default-on path), and offer the apply (deterministically answered
#      here by stub whiptails).
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

# the stub nix: log the full argument vector, then answer the eval target.
# The selection shapes come from the fixture the shim edits (the honest
# loop: the stub re-reads the file the shim wrote, so a shim bug that
# writes a wrong file fails the battery's next read).
cat >"$stub_dir/nix" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> '$root/stub.log'
s=''
case "\$*" in
  *"selections.pins.enable"*) s=enable ;;
  *"selections.pins.disable"*) s=disable ;;
  *"report.selectable."*)
    p=\$(printf '%s' "\$*" | sed -n 's/.*selectable."\([^"]*\)".*/\1/p')
    case "\$p" in
      foundation)
        printf '{"available":true,"baseline":true,"default":true,"kind":"baseline"}\n'
        exit 0
        ;;
      unavailable/thing)
        printf '{"available":false,"baseline":false,"default":true,"kind":"member"}\n'
        exit 0
        ;;
      editor | terminal | terminal/tmux | terminal/nunchux | theme | fonts | secrets | agent | languages)
        printf '{"available":true,"baseline":false,"default":true,"kind":"domain"}\n'
        exit 0
        ;;
      languages/elixir | languages/go | languages/node | languages/typescript)
        printf '{"available":true,"baseline":false,"default":false,"kind":"member"}\n'
        exit 0
        ;;
      *)
        printf 'stub nix: attribute '"'"'workstation.report.selectable."%s"'"'"' does not exist\n' "\$p" >&2
        exit 1
        ;;
    esac
    ;;
esac
[ -n "\$s" ] || { printf '{"stub":true}\n'; exit 0; }
flake=\$(printf '%s' "\$*" | sed 's/.*eval --json //; s/#.*//')
f="\$flake/hosts/selections.nix"
[ "\$s" = enable ] || s=disable
tokens=\$(sed -n "/^  \$s = \[/,/^  \];/p" "\$f" 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' || true)
out=''
for t in \$tokens; do out="\$out\"\$t\","; done
printf '[%s]\n' "\$(printf '%s' "\$out" | sed 's/,\$//')"
STUB
chmod +x "$stub_dir/nix"

# the stub switch driver: log the invocation
{
	printf '#!/bin/sh\n'
	printf 'printf "%%s\\n" "$*" >> %s\n' "'$root/stub.log'"
} > "$stub_dir/workstation-switch"
chmod +x "$stub_dir/workstation-switch"

# stub whiptails: the apply offer answered deterministically (no/yes)
printf '#!/bin/sh\nexit 1\n' > "$stub_dir/whiptail"
chmod +x "$stub_dir/whiptail"

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
printf '%s' "$out" | grep -q 'selected' || fail 'usage must name the selection verbs'
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
mv "$stub_dir/workstation-switch.bak" "$stub_dir/workstation-switch"

# 5. the selection verbs: the grammar, the dedup, the refusal shapes —
# against a fixture checkout whose selections the stub parses from the
# file the shim actually wrote (a shim bug that writes a wrong file fails
# the battery's next read)
sel_fixture=$root/selflake
mkdir -p "$sel_fixture/hosts"
printf '{ host = "selhost"; user = "seluser"; home = "/home/seluser"; tailscaleFqdn = ""; }\n' >"$sel_fixture/hosts/identity.nix"
printf '{\n  enable = [\n  ];\n}\n' >"$sel_fixture/hosts/selections.nix"
sel() { WORKSTATION_FLAKE=$sel_fixture "$shim" "$@"; }

# add writes the row canonically and offers the apply (stub whiptail: no)
out=$(sel add languages/go) || fail 'add must succeed'
grep -q '"languages/go"' "$sel_fixture/hosts/selections.nix" || fail 'add must write the row'
printf '%s' "$out" | grep -q 'next: workstation apply' || fail 'the offer must name the next step'
# dedup: a repeated add is a no-op on the file
sel add languages/go >/dev/null || fail 'a repeated add must succeed'
[ "$(grep -c '"languages/go"' "$sel_fixture/hosts/selections.nix")" = 1 ] ||
	fail 'add must dedup by exact path'
# remove of an unselected default-off member: no write at all
before=$(cat "$sel_fixture/hosts/selections.nix")
out=$(sel remove languages/node) || fail 'remove of an unselected default-off path must succeed'
printf '%s' "$out" | grep -q 'already off' || fail 'the no-op remove must say so'
[ "$before" = "$(cat "$sel_fixture/hosts/selections.nix")" ] ||
	fail 'the no-op remove must not touch the file'
# multiple paths in one invocation; the existing row stays put
sel add languages/node languages/go >/dev/null || fail 'a multi-path add must succeed'
grep -q '"languages/node"' "$sel_fixture/hosts/selections.nix" ||
	fail 'the multi-path add must write its second row'
[ "$(grep -c '"languages/go"' "$sel_fixture/hosts/selections.nix")" = 1 ] ||
	fail 'the multi-path add must not duplicate its first row'
# the apply offer's yes path delegates to the driver
printf '#!/bin/sh\nexit 0\n' > "$stub_dir/whiptail"
sel add languages/elixir >/dev/null 2>&1 || fail 'add must succeed'
expect_log 'apply'
grep -q '"languages/elixir"' "$sel_fixture/hosts/selections.nix" || fail 'the yes path must still write first'
printf '#!/bin/sh\nexit 1\n' > "$stub_dir/whiptail"
# WORKSTATION_NO_APPLY skips the offer's apply
out=$(WORKSTATION_NO_APPLY=1 sel add languages/typescript) || fail 'the NO_APPLY add must succeed'
printf '%s' "$out" | grep -q 'WORKSTATION_NO_APPLY' || fail 'the NO_APPLY add must say the apply was skipped'
# remove of a default-on domain pins it off (the disable section appears)
sel remove editor >/dev/null || fail 'remove editor must succeed'
sed -n '/disable = \[/,$p' "$sel_fixture/hosts/selections.nix" | grep -q '"editor"' ||
	fail 'removing a default-on path must pin it off in the disable section'
# add of the removed path returns: the disable pin leaves, the enable
# row lands
sel add editor >/dev/null || fail 're-add editor must succeed'
grep -q '"editor"' "$sel_fixture/hosts/selections.nix" || fail 'the re-add must write the row'
grep -q 'disable = \[' "$sel_fixture/hosts/selections.nix" &&
	fail 'the re-add must clear the stale disable pin'
# remove of a selected default-off member drops the row without a pin
sel remove languages/go >/dev/null || fail 'remove of a selected language must succeed'
grep -q '"languages/go"' "$sel_fixture/hosts/selections.nix" &&
	fail 'the removed language row must leave the file'
grep -q 'disable = \[' "$sel_fixture/hosts/selections.nix" &&
	fail 'removing a default-off member must not pin it off'
# refusals: baseline, grammar, unknown path — exit 2, no write
before=$(cat "$sel_fixture/hosts/selections.nix")
out=$(sel add foundation 2>&1) && fail 'add foundation must refuse'
printf '%s' "$out" | grep -q 'baseline — always on' || fail 'the baseline refusal must say so'
rc=0; sel add foundation >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "add foundation must exit 2 (got $rc)"
rc=0; sel remove foundation >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "remove foundation must refuse too (got $rc)"
rc=0; sel add 'bad;path' >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "a bad-grammar path must exit 2 (got $rc)"
rc=0; sel add 'a/b/c' >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "a three-segment path must exit 2 (got $rc)"
rc=0; sel add '/leading' >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "a leading-slash path must exit 2 (got $rc)"
rc=0; sel add nonsense >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "an unknown path must exit 2 (got $rc)"
[ "$before" = "$(cat "$sel_fixture/hosts/selections.nix")" ] ||
	fail 'the refusals must not touch the file'
# the availability note: a path the stub marks unavailable warns on stderr
out=$(sel add unavailable/thing 2>&1) || fail 'adding an unavailable path must succeed'
printf '%s' "$out" | grep -q 'unavailable' || fail 'an unavailable path must warn'
# the missing selections file fails closed naming the tree
nofile=$root/nofileflake
mkdir -p "$nofile/hosts"
printf '{ host = "nofile"; user = "nofile"; home = "/home/nofile"; tailscaleFqdn = ""; }\n' >"$nofile/hosts/identity.nix"
rc=0
WORKSTATION_FLAKE=$nofile "$shim" add editor 2>"$root/err" || rc=$?
[ "$rc" = 1 ] || fail "a missing selections file must fail closed (got $rc)"
grep -q 'selections.nix missing' "$root/err" || fail 'the missing-file failure must name it'
# selected evals the report's selections
sel selected >/dev/null || fail 'selected must eval the report'
expect_log '#workstation.report.selections'
rc=0
sel selected extra >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "selected must reject arguments (got $rc)"

echo "$progname: OK (dispatch, resolution order, delegation, fail-closed and selection paths all hold)"
