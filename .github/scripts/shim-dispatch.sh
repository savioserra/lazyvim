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
#   6. init merges hosts/identity.nix: the shipped template's TEMPLATE
#      placeholders are filled from detection, the operator's fields
#      (shellExtras) survive every re-run, a converged identity re-inits
#      byte-identical, a cancelled dialog writes nothing, and a missing
#      template file refuses.
#   8. the write plane switches the resolved checkout: a workstation
#      checkout (identity + shim present) reaches the driver as
#      WORKSTATION_SWITCH_FLAKE for apply and the verbs' apply offer; a
#      foreign flake and the staged snapshot never do; an operator-set
#      WORKSTATION_SWITCH_FLAKE is kept.
#   9. the fleet: init asks once (Turn on -> start/join/standalone, Not
#      now -> standalone), writes `fleet` into the identity and the network
#      domain into the selections (linux), and a re-init keeps the choice;
#      `workstation fleet` re-asks, switches only on a change, then runs
#      the helper (online/login, join) — start never joins, a template
#      identity refuses.
#   7. peers builds the flake's workstation-peers helper and runs it on
#      hosts/peers.nix: arguments refuse, a missing or read-only file
#      refuses, a failed build or helper fails closed, and the apply is
#      offered only when the helper changed the file or reports a saved
#      pairing (exit 10).
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
  *"#workstation-fleet"*)
    printf '%s\n' '$root/fleet-helper'
    exit 0
    ;;
  *"#workstation-peers"*)
    [ -f '$root/peers-build-fails' ] && exit 1
    printf '%s\n' '$root/peers-helper'
    exit 0
    ;;
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

# the stub discovery helper: log the invocation; the mode file picks the
# outcome (touch: change the peers file, paired: exit 10 with the file
# unchanged, fail: exit 1, absent: no change)
mkdir -p "$root/peers-helper/bin"
cat >"$root/peers-helper/bin/workstation-peers" <<STUB
#!/bin/sh
printf 'workstation-peers %s\n' "\$*" >> '$root/stub.log'
mode=\$(cat '$root/peers-mode' 2>/dev/null || true)
case "\$mode" in
  touch) printf '# changed\n' >> "\$1" ;;
  paired) exit 10 ;;
  fail) exit 1 ;;
esac
exit 0
STUB
chmod +x "$root/peers-helper/bin/workstation-peers"

# the stub switch driver: log the invocation and the flake it was handed
cat > "$stub_dir/workstation-switch" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> '$root/stub.log'
printf 'switch-flake=%s\n' "\${WORKSTATION_SWITCH_FLAKE:-}" >> '$root/stub.log'
STUB
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
unset WORKSTATION_FLAKE WORKSTATION_SWITCH_FLAKE

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

\
# 6. init merges hosts/identity.nix: the shipped template's TEMPLATE
# placeholders are filled from detection, the operator's fields
# (shellExtras) survive every re-run, a converged identity re-inits
# byte-identical, a cancelled dialog writes nothing, and a missing
# template file refuses.
init_fixture=$root/initflake
mkdir -p "$init_fixture/hosts"
printf '%s\n' \
	'{' \
	'  host = "TEMPLATE"; # captured by workstation init (hostname -s)' \
	'  user = "TEMPLATE"; # captured by workstation init' \
	'  home = "/home/TEMPLATE"; # captured by workstation init, the home path' \
	'  # shellExtras = "stty -ixon"; # optional: the operator shell lines' \
	'  shellExtras = "stty -ixon"; # the operator'"'"'s own field' \
	'}' >"$init_fixture/hosts/identity.nix"
# 6a. the shipped template: init fills the placeholders from detection
# (the stub whiptail answers every dialog with its default — the detected
# value — the way a real install accepts the prefills) and keeps the
# operator's field byte for byte
cat >"$stub_dir/whiptail" <<'STUB'
#!/bin/sh
# the dialog contract: the gadget result goes to stderr (the fd swap in
# the shim's ask brings it back); the default is the last argument
for a; do :; done
printf '%s\n' "$a" >&2
STUB
cp "$init_fixture/hosts/identity.nix" "$root/init-6a-before"
out=$(WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$init_fixture "$shim" init) ||
	fail 'init on the shipped template must succeed'
printf '%s' "$out" | grep -q 'identity captured' ||
	fail 'the template capture must say it captured'
grep -q 'TEMPLATE' "$init_fixture/hosts/identity.nix" &&
	fail 'init must fill every TEMPLATE placeholder'
grep -Eq '^  host = ".+";' "$init_fixture/hosts/identity.nix" ||
	fail 'init must capture the host'
grep -Eq '^  user = ".+";' "$init_fixture/hosts/identity.nix" ||
	fail 'init must capture the user'
grep -Eq '^  home = ".+";' "$init_fixture/hosts/identity.nix" ||
	fail 'init must capture the home'
grep -q '^  shellExtras = "stty -ixon"; # the operator'"'"'s own field$' \
	"$init_fixture/hosts/identity.nix" ||
	fail 'init must keep the operator shellExtras byte for byte'
grep -q '^  # shellExtras = "stty -ixon";' "$init_fixture/hosts/identity.nix" ||
	fail 'init must keep the comment lines'
# 6b. a converged identity: a re-init is a byte-identical merge no-op
cp "$init_fixture/hosts/identity.nix" "$root/init-6b-before"
out=$(WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$init_fixture "$shim" init) ||
	fail 'a converged re-init must succeed'
printf '%s' "$out" | grep -q 'merged' ||
	fail 'the converged re-init must say it merged'
cmp -s "$root/init-6b-before" "$init_fixture/hosts/identity.nix" ||
	fail 'a converged re-init must not touch the file'
# 6c. an operator-set field wins over detection: the host stays while the
# remaining placeholders fill around it
init2=$root/initflake2
mkdir -p "$init2/hosts"
printf '%s\n' \
	'{' \
	'  host = "myhost"; # captured by workstation init (hostname -s)' \
	'  user = "TEMPLATE";' \
	'  home = "/home/TEMPLATE";' \
	'  shellExtras = "stty -ixon"; # the operator'"'"'s own field' \
	'}' >"$init2/hosts/identity.nix"
WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$init2 "$shim" init >/dev/null ||
	fail 'init on a half-captured identity must succeed'
grep -q '^  host = "myhost";' "$init2/hosts/identity.nix" ||
	fail 'init must keep the operator host over the detected one'
grep -q '^  user = "TEMPLATE";' "$init2/hosts/identity.nix" &&
	fail 'init must fill the placeholder user'
grep -q '^  shellExtras = "stty -ixon";' "$init2/hosts/identity.nix" ||
	fail 'the half-captured merge must keep shellExtras'
# 6d. a cancelled dialog: the capture refuses and writes nothing
printf '{\n  host = "TEMPLATE";\n  user = "TEMPLATE";\n  home = "/home/TEMPLATE";\n  shellExtras = "stty -ixon"; # kept\n}\n' >"$init2/hosts/identity.nix"
cp "$init2/hosts/identity.nix" "$root/init-6d-before"
printf '#!/bin/sh\nexit 1\n' >"$stub_dir/whiptail"
rc=0
WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$init2 "$shim" init >/dev/null 2>"$root/err" || rc=$?
[ "$rc" = 1 ] || fail "a cancelled capture must exit 1 (got $rc)"
grep -q 'cancelled' "$root/err" || fail 'the cancelled capture must say so'
cmp -s "$root/init-6d-before" "$init2/hosts/identity.nix" ||
	fail 'a cancelled capture must not touch the file'
# 6e. a missing template file fails closed
mv "$init2/hosts/identity.nix" "$root/identity.hold"
rc=0
WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$init2 "$shim" init >/dev/null 2>"$root/err" || rc=$?
[ "$rc" = 1 ] || fail "init without the template file must exit 1 (got $rc)"
grep -q 'missing (unexpected tree)' "$root/err" ||
	fail 'the missing-template refusal must name it'
mv "$root/identity.hold" "$init2/hosts/identity.nix"

# 7. peers: the helper build, the file guards, the change-gated offer
peers_fixture=$root/peersflake
mkdir -p "$peers_fixture/hosts"
printf '{ }\n' >"$peers_fixture/hosts/peers.nix"
rc=0
WORKSTATION_FLAKE=$peers_fixture "$shim" peers extra >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "peers with an argument must exit 2 (got $rc)"
# 7a. unchanged file: the helper runs on the file, no apply offer
rm -f "$root/peers-mode"
out=$(WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$peers_fixture "$shim" peers) ||
	fail 'peers with an unchanged file must succeed'
expect_log "#workstation-peers"
expect_log "workstation-peers $peers_fixture/hosts/peers.nix"
printf '%s' "$out" | grep -q 'peers saved' &&
	fail 'an unchanged peers file must not offer the apply'
# 7b. a changed file: the apply offer names the peers
printf 'touch\n' >"$root/peers-mode"
out=$(WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$peers_fixture "$shim" peers) ||
	fail 'peers with a changed file must succeed'
printf '%s' "$out" | grep -q 'peers saved; apply skipped' ||
	fail 'a changed peers file must offer the apply'
# 7b'. a pairing with the file unchanged (exit 10): the apply is offered
printf 'paired\n' >"$root/peers-mode"
out=$(WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$peers_fixture "$shim" peers) ||
	fail 'a saved pairing (exit 10) must not fail the verb'
printf '%s' "$out" | grep -q 'peers saved; apply skipped' ||
	fail 'a saved pairing must offer the apply'
# 7c. a failing helper fails closed
printf 'fail\n' >"$root/peers-mode"
rc=0
WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$peers_fixture "$shim" peers >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "a failing helper must exit 1 (got $rc)"
rm -f "$root/peers-mode"
# 7d. a failed build fails closed naming the helper
: >"$root/peers-build-fails"
rc=0
WORKSTATION_FLAKE=$peers_fixture "$shim" peers >/dev/null 2>"$root/err" || rc=$?
[ "$rc" = 1 ] || fail "a failed helper build must exit 1 (got $rc)"
grep -q 'did not build' "$root/err" || fail 'the failed build must say so'
rm -f "$root/peers-build-fails"
# 7e. a missing or read-only file refuses before any build
chmod a-w "$peers_fixture/hosts/peers.nix"
rc=0
WORKSTATION_FLAKE=$peers_fixture "$shim" peers >/dev/null 2>"$root/err" || rc=$?
chmod u+w "$peers_fixture/hosts/peers.nix"
if [ "$(id -u)" != 0 ]; then
	[ "$rc" = 2 ] || fail "a read-only peers file must exit 2 (got $rc)"
	grep -q 'read-only' "$root/err" || fail 'the read-only refusal must name it'
fi
rm "$peers_fixture/hosts/peers.nix"
rc=0
WORKSTATION_FLAKE=$peers_fixture "$shim" peers >/dev/null 2>"$root/err" || rc=$?
[ "$rc" = 1 ] || fail "a missing peers file must exit 1 (got $rc)"
grep -q 'peers.nix missing' "$root/err" || fail 'the missing-file refusal must name it'

# 8. the write plane switches the resolved checkout
last_switch() { grep '^switch-flake=' "$root/stub.log" | tail -n 1; }
co=$root/checkout
mkdir -p "$co/hosts" "$co/bin" "$co/docs"
printf '{ host = "cohost"; user = "couser"; home = "/home/couser"; }\n' >"$co/hosts/identity.nix"
printf '{\n  enable = [\n  ];\n}\n' >"$co/hosts/selections.nix"
: >"$co/bin/workstation"
: >"$co/flake.nix"
co_real=$(CDPATH='' cd -P "$co" && pwd -P)
# 8a. apply inside the checkout (the enclosing walk) hands it over
(cd "$co/docs" && "$shim" apply >/dev/null 2>&1) || fail 'apply inside a checkout must delegate'
[ "$(last_switch)" = "switch-flake=$co_real" ] ||
	fail "apply inside a checkout must hand the checkout to the driver (got: $(last_switch))"
# 8b. the apply offer after an edit hands it over too (stub whiptail: yes)
printf '#!/bin/sh\nexit 0\n' > "$stub_dir/whiptail"
WORKSTATION_FLAKE=$co "$shim" add languages/go >/dev/null 2>&1 || fail 'add in a checkout must succeed'
[ "$(last_switch)" = "switch-flake=$co_real" ] ||
	fail "the apply offer must switch the edited checkout (got: $(last_switch))"
printf '#!/bin/sh\nexit 1\n' > "$stub_dir/whiptail"
# 8c. a foreign flake (no identity, no shim) is never handed over
WORKSTATION_FLAKE=$fixture "$shim" apply >/dev/null 2>&1 || fail 'apply must delegate'
[ "$(last_switch)" = "switch-flake=" ] ||
	fail "a non-checkout flake must not reach the driver (got: $(last_switch))"
# 8d. the staged snapshot stays the driver's default
mkdir -p "$root/snaphome/.local/opt/workstation/flake/hosts" "$root/snaphome/.local/opt/workstation/flake/bin"
: >"$root/snaphome/.local/opt/workstation/flake/hosts/identity.nix"
: >"$root/snaphome/.local/opt/workstation/flake/bin/workstation"
(cd "$root/snaphome" && HOME=$root/snaphome "$shim" apply >/dev/null 2>&1) || fail 'apply via the snapshot must delegate'
[ "$(last_switch)" = "switch-flake=" ] ||
	fail "the staged snapshot must not be handed over (got: $(last_switch))"
# 8e. an operator-set override wins
(cd "$co" && WORKSTATION_SWITCH_FLAKE=/operator/flake "$shim" apply >/dev/null 2>&1) || fail 'apply must delegate'
[ "$(last_switch)" = "switch-flake=/operator/flake" ] ||
	fail "an operator-set WORKSTATION_SWITCH_FLAKE must win (got: $(last_switch))"

# 9. the fleet
mkdir -p "$root/fleet-helper/bin"
cat >"$root/fleet-helper/bin/workstation-fleet" <<STUB
#!/bin/sh
printf 'workstation-fleet %s\n' "\$*" >> '$root/stub.log'
[ "\$1" = online ] && exit "\$(cat '$root/fleet-online' 2>/dev/null || echo 0)"
exit 0
STUB
chmod +x "$root/fleet-helper/bin/workstation-fleet"
# the queue whiptail: answers in order (yes/no for --yesno, a tag otherwise);
# an exhausted queue is ESC
cat >"$stub_dir/whiptail" <<STUB
#!/bin/sh
kind=''
for a; do case \$a in --yesno|--menu|--msgbox|--inputbox) kind=\$a ;; esac; done
[ "\$kind" = --msgbox ] && exit 0
q='$root/wt-queue'
[ -s "\$q" ] || exit 1
ans=\$(head -n 1 "\$q"); sed -i '1d' "\$q"
printf 'whiptail %s -> %s\n' "\$kind" "\$ans" >> '$root/stub.log'
if [ "\$kind" = --yesno ]; then [ "\$ans" = yes ]; exit; fi
printf '%s\n' "\$ans" >&2
STUB
chmod +x "$stub_dir/whiptail"
fl=$root/fleetflake
mkdir -p "$fl/hosts" "$fl/bin"
: >"$fl/bin/workstation"
: >"$fl/flake.nix"
fleet_template() {
	printf '%s\n' '{' '  host = "TEMPLATE";' '  user = "TEMPLATE";' '  home = "/home/TEMPLATE";' \
		'  # fleet = "member"; # the commented example never matches' '}' >"$fl/hosts/identity.nix"
	printf '{\n  enable = [\n  ];\n}\n' >"$fl/hosts/selections.nix"
}
# 9a. init: Turn on -> Join (detected values accepted: the queue answers
# the three captures with their defaults first)
fleet_template
printf '%s\n' "$(uname -n | cut -d. -f1)" "${USER:-$(id -un)}" "$HOME" yes join >"$root/wt-queue"
WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$fl "$shim" init >/dev/null 2>&1 || fail 'init with the fleet join must succeed'
grep -q '^  fleet = "member";$' "$fl/hosts/identity.nix" || fail 'Join must capture fleet = "member"'
grep -q '^  # fleet = "member";' "$fl/hosts/identity.nix" || fail 'the commented example must survive'
if [ "$(uname -s)" = Linux ]; then
	grep -q '"network"' "$fl/hosts/selections.nix" || fail 'Join must select the network domain on the home leg'
fi
# 9b. a re-init keeps the choice and asks nothing (an empty queue is ESC)
cp "$fl/hosts/identity.nix" "$root/fleet-9b"
: >"$root/wt-queue"
WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$fl "$shim" init >/dev/null 2>&1 || fail 'a converged re-init must succeed'
cmp -s "$root/fleet-9b" "$fl/hosts/identity.nix" || fail 'a re-init must keep the fleet choice byte for byte'
# 9c. init: Not now -> standalone
fleet_template
printf '%s\n' "$(uname -n | cut -d. -f1)" "${USER:-$(id -un)}" "$HOME" no >"$root/wt-queue"
WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$fl "$shim" init >/dev/null 2>&1 || fail 'init with Not now must succeed'
grep -q '^  fleet = "standalone";$' "$fl/hosts/identity.nix" || fail 'Not now must capture fleet = "standalone"'
grep -q '"network"' "$fl/hosts/selections.nix" && fail 'Not now must not select the network domain'
# 9d. workstation fleet: standalone -> Start switches once, never joins
: >"$root/stub.log"
printf '%s\n' yes start >"$root/wt-queue"
WORKSTATION_FLAKE=$fl "$shim" fleet >/dev/null 2>&1 || fail 'fleet start must succeed'
grep -q '^  fleet = "member";$' "$fl/hosts/identity.nix" || fail 'Start must capture fleet = "member"'
[ "$(grep -c '^apply$' "$root/stub.log")" = 1 ] || fail 'a changed choice must switch once'
grep -q 'workstation-fleet online' "$root/stub.log" || fail 'the fleet must check the tailnet login'
grep -q 'workstation-fleet join' "$root/stub.log" && fail 'Start must never join'
# 9e. workstation fleet: an unchanged choice joins without a switch
: >"$root/stub.log"
printf '%s\n' yes join >"$root/wt-queue"
WORKSTATION_FLAKE=$fl "$shim" fleet >/dev/null 2>&1 || fail 'fleet join must succeed'
grep -q '^apply$' "$root/stub.log" && fail 'an unchanged choice must not switch'
grep -q 'workstation-fleet join' "$root/stub.log" || fail 'Join must run the helper join'
# 9f. logged out and Later: no join, the fix named
: >"$root/stub.log"
printf '1\n' >"$root/fleet-online"
printf '%s\n' yes join no >"$root/wt-queue"
out=$(WORKSTATION_FLAKE=$fl "$shim" fleet 2>&1) || fail 'a deferred login must not fail the verb'
grep -q 'workstation-fleet join' "$root/stub.log" && fail 'a logged-out node must not join'
printf '%s' "$out" | grep -q 'tailscale up' || fail 'the deferred login must name the command'
rm -f "$root/fleet-online"
# 9g. a template identity refuses
fleet_template
rc=0
WORKSTATION_FLAKE=$fl "$shim" fleet >/dev/null 2>"$root/err" || rc=$?
[ "$rc" = 2 ] || fail "fleet on a template identity must exit 2 (got $rc)"
grep -q 'workstation init' "$root/err" || fail 'the refusal must name workstation init'

echo "$progname: OK (dispatch, resolution order, delegation, fail-closed, selection, init-merge, peers, switch-checkout and fleet paths all hold)"
