#!/bin/sh
# The launcher's dispatch gate: the real bin/workstation against a stub
# `nix`, stub dialogs and stub drivers on a private PATH.
#
# | # | Contract |
# | --- | --- |
# | 1 | help and the bare verb print usage (exit 0); unknown verbs/options exit 2 |
# | 2 | a read evals #workstation.report.<verb> on the resolved flake and prints it unchanged |
# | 3 | resolution: --flake > $WORKSTATION_FLAKE > the enclosing checkout > the staged snapshot; none fails closed |
# | 4 | writes delegate to workstation-switch; an uncaptured machine refuses; no driver fails closed |
# | 5 | add/remove: grammar, report row, baseline refusal; hosts/local/machine.json settings edited, pruned, apply offered |
# | 6 | init: placeholders filled from detection, set fields kept, a converged re-init byte-identical, cancel writes nothing |
# | 7 | peers: helper build, file guards, change-gated apply offer |
# | 8 | the write plane switches the resolved checkout only |
# | 9 | fleet: asked once, member/standalone written to the machine file, re-asked by `workstation fleet` |
set -eu
progname='shim-dispatch.sh'
repo_root=$(CDPATH='' cd -P "$(dirname "$0")/../.." && pwd -P)
shim=$repo_root/bin/workstation
[ -f "$shim" ] || { echo "$progname: the shim is missing at bin/workstation" >&2; exit 1; }

WORKSTATION_JQ=$(command -v jq 2>/dev/null) ||
	WORKSTATION_JQ=$(nix --extra-experimental-features 'nix-command flakes' build --no-link --print-out-paths nixpkgs#jq.bin)/bin/jq
export WORKSTATION_JQ
jq=$WORKSTATION_JQ

root=$(mktemp -d "${TMPDIR:-/tmp}/shim-dispatch.XXXXXX")
trap 'rm -rf "$root"' EXIT
stub_dir=$root/stub
mkdir -p "$stub_dir"
: > "$root/stub.log"

cat >"$stub_dir/nix" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> '$root/stub.log'
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
  *"report.selectable."*)
    p=\$(printf '%s' "\$*" | sed -n 's/.*selectable."\([^"]*\)".*/\1/p')
    case "\$p" in
      foundation) printf '{"baseline":true,"default":true,"kind":"baseline"}\n' ;;
      editor | terminal | terminal/tmux | theme | fonts | secrets | agent | languages)
        printf '{"baseline":false,"default":true,"kind":"domain"}\n' ;;
      network | languages/elixir | languages/go | languages/node | languages/typescript)
        printf '{"baseline":false,"default":false,"kind":"member"}\n' ;;
      *)
        printf 'stub nix: attribute does not exist\n' >&2
        exit 1
        ;;
    esac
    exit 0
    ;;
  *"report.selectable"*)
    printf '%s\n' '{"languages/elixir":{"baseline":false,"default":false,"kind":"member"},"languages/go":{"baseline":false,"default":false,"kind":"member"},"languages/node":{"baseline":false,"default":false,"kind":"member"},"languages/typescript":{"baseline":false,"default":false,"kind":"member"},"editor":{"baseline":false,"default":true,"kind":"domain"},"foundation":{"baseline":true,"default":true,"kind":"baseline"}}'
    exit 0
    ;;
esac
printf '{"stub":true}\n'
STUB
chmod +x "$stub_dir/nix"

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

cat > "$stub_dir/workstation-switch" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> '$root/stub.log'
printf 'switch-flake=%s\n' "\${WORKSTATION_SWITCH_FLAKE:-}" >> '$root/stub.log'
printf 'switch-machine=%s\n' "\${WORKSTATION_SWITCH_MACHINE:-}" >> '$root/stub.log'
STUB
chmod +x "$stub_dir/workstation-switch"

printf '#!/bin/sh\nexit 1\n' > "$stub_dir/whiptail"
chmod +x "$stub_dir/whiptail"

fail() { echo "$progname: FAIL: $*" >&2; exit 1; }
expect_log() {
	grep -Fq "$1" "$root/stub.log" || fail "expected stub log line '$1' (got: $(tail -1 "$root/stub.log"))"
}
# machine <dir> <json> — a fixture checkout's machine file
machine() {
	mkdir -p "$1/hosts/local" "$1/hosts/template"
	printf '%s\n' "$2" >"$1/hosts/local/machine.json"
	[ -f "$1/hosts/template/peers.nix" ] || printf '{ }\n' >"$1/hosts/template/peers.nix"
}
captured='{"host":"testhost","user":"testuser","home":"/home/testuser","system":"x86_64-linux","settings":{}}'
template='{"host":"TEMPLATE","user":"TEMPLATE","home":"/home/TEMPLATE","settings":{}}'
# q <dir> <jq filter> — query a fixture's machine file
q() { "$jq" -r "$2" "$1/hosts/local/machine.json"; }

PATH=$stub_dir:/usr/bin:/bin
export PATH
unset WORKSTATION_FLAKE WORKSTATION_SWITCH_FLAKE WORKSTATION_CHECKOUT WORKSTATION_WORKTREE
repo_ref="git+file://$repo_root?rev=$(git -C "$repo_root" rev-parse HEAD)"
repo_ovr=''
[ ! -f "$repo_root/hosts/local/machine.json" ] || repo_ovr=" --override-input machine-files path:$repo_root/hosts/local"

# 1
out=$("$shim" help) || fail 'help must exit 0'
printf '%s' "$out" | grep -q 'workstation.report' || fail 'usage must name the read surface'
printf '%s' "$out" | grep -q 'selected' || fail 'usage must name the selection verbs'
out=$("$shim") || fail 'the bare verb must exit 0'
printf '%s' "$out" | grep -q 'workstation —' || fail 'the bare verb prints usage'
rc=0
"$shim" frobnicate >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "unknown verb must exit 2 (got $rc)"
rc=0
"$shim" --bogus >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "unknown option must exit 2 (got $rc)"

# 2
out=$("$shim" --flake "$repo_root" status) || fail 'status with an explicit flake failed'
[ "$out" = '{"stub":true}' ] || fail 'the read must print the eval stdout unchanged'
expect_log "eval --json $repo_ref#workstation.report.status$repo_ovr"

# 3
WORKSTATION_FLAKE=$repo_root "$shim" plan >/dev/null || fail 'plan via WORKSTATION_FLAKE failed'
expect_log "$repo_ref#workstation.report.plan"
(cd "$repo_root/docs" && "$shim" capabilities >/dev/null) || fail 'capabilities via the checkout walk failed'
expect_log "$repo_ref#workstation.report.capabilities"
mkdir -p "$root/home"
: >"$root/stub.log"
(cd "$root/home" && HOME=$root/home WORKSTATION_CHECKOUT=$repo_root "$shim" status >/dev/null) || fail 'status via the recorded checkout failed'
expect_log "$repo_ref#workstation.report.status"
(cd "$root" && HOME=$root/bare "$shim" status 2>"$root/err") && fail 'a bare host read must fail closed'
grep -q 'no checkout to read' "$root/err" || fail 'the bare-host failure must name the fix'
(cd "$repo_root" && "$shim" capabilities languages/go >/dev/null) || fail 'a scoped read failed'
expect_log "$repo_ref#workstation.report.capabilities.\"languages/go\""
"$shim" capabilities 'bad;name' >/dev/null 2>&1 && fail 'a scope element must be a plain attribute name'

# 4
tpl=$root/templateflake
machine "$tpl" "$template"
rc=0
WORKSTATION_FLAKE=$tpl "$shim" apply 2>"$root/err" || rc=$?
[ "$rc" = 2 ] || fail 'apply must refuse the uncaptured machine with exit 2'
grep -q 'workstation init' "$root/err" || fail 'the refusal must name workstation init'
fixture=$root/fakeflake
machine "$fixture" "$captured"
WORKSTATION_FLAKE=$fixture "$shim" apply >/dev/null 2>&1 || fail 'apply must delegate to the staged driver'
expect_log 'apply'
WORKSTATION_FLAKE=$fixture "$shim" rollback --system >/dev/null 2>&1 || fail 'rollback --system must delegate'
expect_log 'rollback --system'
mv "$stub_dir/workstation-switch" "$stub_dir/workstation-switch.bak"
rc=0
WORKSTATION_FLAKE=$fixture "$shim" apply 2>"$root/err" || rc=$?
[ "$rc" = 2 ] || fail 'apply without a driver must fail closed'
grep -q 'workstation-switch' "$root/err" || fail 'the missing-driver failure must name the driver'
mv "$stub_dir/workstation-switch.bak" "$stub_dir/workstation-switch"

# 5
sf=$root/selflake
machine "$sf" "$captured"
sel() { WORKSTATION_FLAKE=$sf "$shim" "$@"; }
out=$(sel add languages/go) || fail 'add must succeed'
[ "$(q "$sf" .settings.workstation.languages.go.enable)" = true ] || fail 'add must set the enable'
printf '%s' "$out" | grep -q 'next: workstation apply' || fail 'the offer must name the next step'
before=$(cat "$sf/hosts/local/machine.json")
out=$(sel add languages/go) || fail 'a repeated add must succeed'
printf '%s' "$out" | grep -q 'already selected' || fail 'a repeated add must say so'
[ "$before" = "$(cat "$sf/hosts/local/machine.json")" ] || fail 'a repeated add must not touch the file'
out=$(sel remove languages/node) || fail 'remove of an unselected default-off path must succeed'
printf '%s' "$out" | grep -q 'already off' || fail 'the no-op remove must say so'
[ "$before" = "$(cat "$sf/hosts/local/machine.json")" ] || fail 'the no-op remove must not touch the file'
sel add languages/node languages/go >/dev/null || fail 'a multi-path add must succeed'
[ "$(q "$sf" .settings.workstation.languages.node.enable)" = true ] || fail 'the multi-path add must set its second path'
printf '#!/bin/sh\nexit 0\n' > "$stub_dir/whiptail"
sel add languages/elixir >/dev/null 2>&1 || fail 'add must succeed'
expect_log 'apply'
[ "$(q "$sf" .settings.workstation.languages.elixir.enable)" = true ] || fail 'the yes path must still write first'
printf '#!/bin/sh\nexit 1\n' > "$stub_dir/whiptail"
out=$(WORKSTATION_NO_APPLY=1 sel add languages/typescript) || fail 'the NO_APPLY add must succeed'
printf '%s' "$out" | grep -q 'WORKSTATION_NO_APPLY' || fail 'the NO_APPLY add must say the apply was skipped'
sel remove editor >/dev/null || fail 'remove editor must succeed'
[ "$(q "$sf" .settings.workstation.editor.enable)" = false ] || fail 'removing a default-on path must pin it off'
sel add editor >/dev/null || fail 're-add editor must succeed'
[ "$(q "$sf" .settings.workstation.editor.enable)" = true ] || fail 'the re-add must turn the pin on'
sel remove languages/go >/dev/null || fail 'remove of a selected language must succeed'
[ "$(q "$sf" '.settings.workstation.languages.go // "gone"')" = gone ] || fail 'removing a default-off member must drop its key'
sel remove languages >/dev/null || fail 'remove of the languages domain must succeed'
sel add languages/go >/dev/null || fail 'a member add under a disabled domain must succeed'
[ "$(q "$sf" .settings.workstation.languages.enable)" = true ] || fail 'a member add must turn its disabled domain on'
before=$(cat "$sf/hosts/local/machine.json")
out=$(sel add foundation 2>&1) && fail 'add foundation must refuse'
printf '%s' "$out" | grep -q 'baseline — always on' || fail 'the baseline refusal must say so'
for bad in foundation 'bad;path' a/b/c /leading nonsense; do
	rc=0
	sel add "$bad" >/dev/null 2>&1 || rc=$?
	[ "$rc" = 2 ] || fail "add '$bad' must exit 2 (got $rc)"
done
[ "$before" = "$(cat "$sf/hosts/local/machine.json")" ] || fail 'the refusals must not touch the file'
nofile=$root/nofileflake
mkdir -p "$nofile/hosts"
rc=0
WORKSTATION_FLAKE=$nofile "$shim" add editor 2>"$root/err" || rc=$?
[ "$rc" = 2 ] || fail "a missing machine file must fail closed (got $rc)"
grep -q 'workstation init' "$root/err" || fail 'the missing-file failure must name workstation init'
sel selected >/dev/null || fail 'selected must eval the report'
expect_log '#workstation.report.selections'
rc=0
sel selected extra >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "selected must reject arguments (got $rc)"

# 6
cat >"$stub_dir/whiptail" <<'STUB'
#!/bin/sh
for a; do :; done
printf '%s\n' "$a" >&2
STUB
init=$root/initflake
machine "$init" '{"host":"TEMPLATE","user":"TEMPLATE","home":"/home/TEMPLATE","settings":{"workstation":{"foundation":{"shell":{"extras":"stty -ixon"}}},"programs":{"hermes":{"a2a":{"enable":true}}}}}'
out=$(WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$init "$shim" init) || fail 'init on the template must succeed'
printf '%s' "$out" | grep -q 'machine captured' || fail 'the capture must say it captured'
grep -q TEMPLATE "$init/hosts/local/machine.json" && fail 'init must fill every placeholder'
[ "$(q "$init" .host)" = "$(uname -n | cut -d. -f1)" ] || fail 'init must capture the host'
[ "$(q "$init" .home)" = "$HOME" ] || fail 'init must capture the home'
q "$init" .system | grep -Eq '^(x86_64|aarch64)-(linux|darwin)$' || fail 'init must capture the system'
[ "$(q "$init" .settings.workstation.foundation.shell.extras)" = 'stty -ixon' ] || fail 'init must keep the settings'
cp "$init/hosts/local/machine.json" "$root/init-before"
out=$(WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$init "$shim" init) || fail 'a converged re-init must succeed'
printf '%s' "$out" | grep -q 'already captured' || fail 'the converged re-init must say so'
cmp -s "$root/init-before" "$init/hosts/local/machine.json" || fail 'a converged re-init must not touch the file'
machine "$init" '{"host":"myhost","user":"TEMPLATE","home":"/home/TEMPLATE","system":"aarch64-linux","settings":{"programs":{"hermes":{"a2a":{"enable":true}}}}}'
WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$init "$shim" init >/dev/null || fail 'init on a half-captured machine must succeed'
[ "$(q "$init" .host)" = myhost ] || fail 'init must keep the operator host'
[ "$(q "$init" .system)" = aarch64-linux ] || fail 'init must keep the operator system'
[ "$(q "$init" .user)" != TEMPLATE ] || fail 'init must fill the placeholder user'
machine "$init" "$template"
cp "$init/hosts/local/machine.json" "$root/init-before"
printf '#!/bin/sh\nexit 1\n' >"$stub_dir/whiptail"
rc=0
WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$init "$shim" init >/dev/null 2>"$root/err" || rc=$?
[ "$rc" = 1 ] || fail "a cancelled capture must exit 1 (got $rc)"
grep -q 'cancelled' "$root/err" || fail 'the cancelled capture must say so'
cmp -s "$root/init-before" "$init/hosts/local/machine.json" || fail 'a cancelled capture must not touch the file'
rm "$init/hosts/local/machine.json"
mkdir -p "$init/hosts/template"
printf '%s\n' "$template" >"$init/hosts/template/machine.json"
printf '{ }\n' >"$init/hosts/template/peers.nix"
cat >"$stub_dir/whiptail" <<'STUB'
#!/bin/sh
for a; do :; done
printf '%s\n' "$a" >&2
STUB
WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$init "$shim" init >/dev/null 2>&1 || fail 'init must seed hosts/local from the template'
[ -f "$init/hosts/local/peers.nix" ] || fail 'init must seed peers.nix from the template'
grep -q TEMPLATE "$init/hosts/local/machine.json" && fail 'the seeded capture must fill every placeholder'
rm -r "$init/hosts/local" "$init/hosts/template"
printf '#!/bin/sh\nexit 1\n' >"$stub_dir/whiptail"
rc=0
WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$init "$shim" init >/dev/null 2>"$root/err" || rc=$?
[ "$rc" = 1 ] || fail "init without a template must exit 1 (got $rc)"
grep -q 'missing (unexpected tree)' "$root/err" || fail 'the missing-template refusal must name it'

# 6b
sp=$root/setupflake
machine "$sp" '{"host":"oldhost","user":"testuser","home":"/home/testuser","system":"x86_64-linux","settings":{"workstation":{"languages":{"go":{"enable":true}}}}}'
cat >"$stub_dir/whiptail" <<'STUB'
#!/bin/sh
kind=''
prompt=''
prev=''
for a; do
	case $prev in --inputbox|--yesno) prompt=$a ;; esac
	case $a in --yesno|--menu|--msgbox|--inputbox|--checklist) kind=$a ;; esac
	prev=$a
done
case $kind in
--msgbox) exit 0 ;;
--yesno) exit 1 ;;
--checklist) printf '"elixir" "go"\n' >&2; exit 0 ;;
--menu) printf 'standalone\n' >&2; exit 0 ;;
esac
case $prompt in
*hostname*) printf 'newhost\n' >&2 ;;
*operator\ user*) printf 'testuser\n' >&2 ;;
*home\ directory*) printf '/home/testuser\n' >&2 ;;
*) exit 1 ;;
esac
STUB
chmod +x "$stub_dir/whiptail"
WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$sp "$shim" setup >/dev/null 2>&1 ||
	fail 'setup must rerun the inquiry'
[ "$(q "$sp" .host)" = newhost ] ||
	fail "setup must re-ask a captured field (got host: $(q "$sp" .host))"
[ "$(q "$sp" .settings.workstation.languages.elixir.enable)" = true ] ||
	fail 'setup must record a checked language'
[ "$(q "$sp" .settings.workstation.languages.go.enable)" = true ] ||
	fail 'setup must keep an already-checked language checked'
[ "$(q "$sp" '.settings.workstation.languages.node // "absent"')" = absent ] ||
	fail 'an unchecked default-off language stays unset'
fleet_state_sp() { q "$sp" '[.settings.programs.hermes.a2a.enable, .settings.workstation.network.enable] | map(tostring) | join(" ")'; }
[ "$(fleet_state_sp)" = 'false false' ] || fail "setup must re-ask the fleet choice (got: $(fleet_state_sp))"

# 7
pf=$root/peersflake
mkdir -p "$pf/hosts/local"
printf '{ }\n' >"$pf/hosts/local/peers.nix"
rc=0
WORKSTATION_FLAKE=$pf "$shim" peers extra >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "peers with an argument must exit 2 (got $rc)"
rm -f "$root/peers-mode"
out=$(WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$pf "$shim" peers) || fail 'peers with an unchanged file must succeed'
expect_log "#workstation-peers"
expect_log "workstation-peers $pf/hosts/local/peers.nix"
printf '%s' "$out" | grep -q 'peers saved' && fail 'an unchanged peers file must not offer the apply'
printf 'touch\n' >"$root/peers-mode"
out=$(WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$pf "$shim" peers) || fail 'peers with a changed file must succeed'
printf '%s' "$out" | grep -q 'peers saved; apply skipped' || fail 'a changed peers file must offer the apply'
printf 'paired\n' >"$root/peers-mode"
out=$(WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$pf "$shim" peers) || fail 'a saved pairing (exit 10) must not fail the verb'
printf '%s' "$out" | grep -q 'peers saved; apply skipped' || fail 'a saved pairing must offer the apply'
printf 'fail\n' >"$root/peers-mode"
rc=0
WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$pf "$shim" peers >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "a failing helper must exit 1 (got $rc)"
rm -f "$root/peers-mode"
: >"$root/peers-build-fails"
rc=0
WORKSTATION_FLAKE=$pf "$shim" peers >/dev/null 2>"$root/err" || rc=$?
[ "$rc" = 1 ] || fail "a failed helper build must exit 1 (got $rc)"
grep -q 'did not build' "$root/err" || fail 'the failed build must say so'
rm -f "$root/peers-build-fails"
chmod a-w "$pf/hosts/local/peers.nix"
rc=0
WORKSTATION_FLAKE=$pf "$shim" peers >/dev/null 2>"$root/err" || rc=$?
chmod u+w "$pf/hosts/local/peers.nix"
if [ "$(id -u)" != 0 ]; then
	[ "$rc" = 2 ] || fail "a read-only peers file must exit 2 (got $rc)"
	grep -q 'read-only' "$root/err" || fail 'the read-only refusal must name it'
fi
rm "$pf/hosts/local/peers.nix"
rc=0
WORKSTATION_FLAKE=$pf "$shim" peers >/dev/null 2>"$root/err" || rc=$?
[ "$rc" = 1 ] || fail "a missing peers file must exit 1 (got $rc)"
grep -q 'peers.nix missing' "$root/err" || fail 'the missing-file refusal must name it'

# 8
last_switch() { grep '^switch-flake=' "$root/stub.log" | tail -n 1; }
co=$root/checkout
machine "$co" "$captured"
mkdir -p "$co/bin" "$co/docs"
: >"$co/bin/workstation"
: >"$co/flake.nix"
co_real=$(CDPATH='' cd -P "$co" && pwd -P)
(cd "$co/docs" && "$shim" apply >/dev/null 2>&1) || fail 'apply inside a checkout must delegate'
[ "$(last_switch)" = "switch-flake=$co_real" ] || fail "apply inside a checkout must hand it over (got: $(last_switch))"
printf '#!/bin/sh\nexit 0\n' > "$stub_dir/whiptail"
WORKSTATION_FLAKE=$co "$shim" add languages/go >/dev/null 2>&1 || fail 'add in a checkout must succeed'
[ "$(last_switch)" = "switch-flake=$co_real" ] || fail "the apply offer must switch the edited checkout (got: $(last_switch))"
printf '#!/bin/sh\nexit 1\n' > "$stub_dir/whiptail"
WORKSTATION_FLAKE=$fixture "$shim" apply >/dev/null 2>&1 || fail 'apply must delegate'
[ "$(last_switch)" = "switch-flake=" ] || fail "a flake without the launcher must not reach the driver (got: $(last_switch))"
last_machine() { grep '^switch-machine=' "$root/stub.log" | tail -n 1; }
[ "$(last_machine)" = "switch-machine=" ] || fail "a flake without the launcher must not hand over machine files (got: $(last_machine))"
gco=$root/gitcheckout
machine "$gco" "$captured"
mkdir -p "$gco/bin"
: >"$gco/bin/workstation"
: >"$gco/flake.nix"
printf 'hosts/local/\n' >"$gco/.gitignore"
git -C "$gco" init -q
git -C "$gco" add -A
git -C "$gco" -c user.name=t -c user.email=t@t commit -qm fixture
gco_real=$(CDPATH='' cd -P "$gco" && pwd -P)
gco_rev=$(git -C "$gco" rev-parse HEAD)
printf 'work in progress\n' >"$gco/bin/workstation"
(cd "$gco" && "$shim" apply >/dev/null 2>&1) || fail 'apply in a git checkout must delegate'
[ "$(last_switch)" = "switch-flake=git+file://$gco_real?rev=$gco_rev" ] || fail "a git checkout must hand over its committed HEAD (got: $(last_switch))"
[ "$(last_machine)" = "switch-machine=$gco_real/hosts/local" ] || fail "a git checkout must hand over its working-tree machine files (got: $(last_machine))"
(cd "$gco" && WORKSTATION_WORKTREE=1 "$shim" apply >/dev/null 2>&1) || fail 'apply with WORKSTATION_WORKTREE must delegate'
[ "$(last_switch)" = "switch-flake=$gco_real" ] || fail "WORKSTATION_WORKTREE must hand over the working tree (got: $(last_switch))"
(cd "$co" && WORKSTATION_SWITCH_FLAKE=/operator/flake "$shim" apply >/dev/null 2>&1) || fail 'apply must delegate'
[ "$(last_switch)" = "switch-flake=/operator/flake" ] || fail "an operator-set WORKSTATION_SWITCH_FLAKE must win (got: $(last_switch))"

# 9
mkdir -p "$root/fleet-helper/bin"
cat >"$root/fleet-helper/bin/workstation-fleet" <<STUB
#!/bin/sh
printf 'workstation-fleet %s\n' "\$*" >> '$root/stub.log'
[ "\$1" = online ] && exit "\$(cat '$root/fleet-online' 2>/dev/null || echo 0)"
exit 0
STUB
chmod +x "$root/fleet-helper/bin/workstation-fleet"
cat >"$stub_dir/whiptail" <<STUB
#!/bin/sh
kind=''
for a; do case \$a in --yesno|--menu|--msgbox|--inputbox|--checklist) kind=\$a ;; esac; done
[ "\$kind" = --msgbox ] && exit 0
[ "\$kind" = --checklist ] && exit 0
q='$root/wt-queue'
[ -s "\$q" ] || exit 1
ans=\$(head -n 1 "\$q"); sed -i '1d' "\$q"
printf 'whiptail %s -> %s\n' "\$kind" "\$ans" >> '$root/stub.log'
if [ "\$kind" = --yesno ]; then [ "\$ans" = yes ]; exit; fi
printf '%s\n' "\$ans" >&2
STUB
chmod +x "$stub_dir/whiptail"
cat >"$stub_dir/tailscale" <<STUB
#!/bin/sh
exit "\$(cat '$root/ts-online' 2>/dev/null || echo 1)"
STUB
chmod +x "$stub_dir/tailscale"
fl=$root/fleetflake
mkdir -p "$fl/bin"
: >"$fl/bin/workstation"
: >"$fl/flake.nix"
fleet_state() { q "$fl" '[.settings.programs.hermes.a2a.enable, .settings.workstation.network.enable] | map(tostring) | join(" ")'; }
machine "$fl" "$template"
printf '%s\n' "$(uname -n | cut -d. -f1)" "${USER:-$(id -un)}" "$HOME" yes join >"$root/wt-queue"
WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$fl "$shim" init >/dev/null 2>&1 || fail 'init with the fleet join must succeed'
[ "$(fleet_state)" = 'true true' ] || fail "Join must turn the A2A node and the network on (got: $(fleet_state))"
cp "$fl/hosts/local/machine.json" "$root/fleet-before"
: >"$root/wt-queue"
WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$fl "$shim" init >/dev/null 2>&1 || fail 'a converged re-init must succeed'
cmp -s "$root/fleet-before" "$fl/hosts/local/machine.json" || fail 'a re-init must keep the fleet choice byte for byte'
machine "$fl" "$template"
printf '%s\n' "$(uname -n | cut -d. -f1)" "${USER:-$(id -un)}" "$HOME" no >"$root/wt-queue"
WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE=$fl "$shim" init >/dev/null 2>&1 || fail 'init with Not now must succeed'
[ "$(fleet_state)" = 'false false' ] || fail "Not now must turn both off (got: $(fleet_state))"
: >"$root/stub.log"
printf '%s\n' yes start >"$root/wt-queue"
WORKSTATION_FLAKE=$fl "$shim" fleet >/dev/null 2>&1 || fail 'fleet start must succeed'
[ "$(fleet_state)" = 'true true' ] || fail 'Start must turn the fleet on'
[ "$(grep -c '^apply$' "$root/stub.log")" = 1 ] || fail 'a changed choice must switch once'
grep -q 'workstation-fleet online' "$root/stub.log" || fail 'the fleet must check the tailnet login'
grep -q 'workstation-fleet join' "$root/stub.log" && fail 'Start must never join'
: >"$root/stub.log"
printf '%s\n' yes join >"$root/wt-queue"
WORKSTATION_FLAKE=$fl "$shim" fleet >/dev/null 2>&1 || fail 'fleet join must succeed'
grep -q '^apply$' "$root/stub.log" && fail 'an unchanged choice must not switch'
grep -q 'workstation-fleet join' "$root/stub.log" || fail 'Join must run the helper join'
: >"$root/stub.log"
printf '1\n' >"$root/fleet-online"
printf '%s\n' yes join no >"$root/wt-queue"
out=$(WORKSTATION_FLAKE=$fl "$shim" fleet 2>&1) || fail 'a deferred login must not fail the verb'
grep -q 'workstation-fleet join' "$root/stub.log" && fail 'a logged-out node must not join'
printf '%s' "$out" | grep -q 'tailscale up' || fail 'the deferred login must name the command'
rm -f "$root/fleet-online"
printf '0\n' >"$root/ts-online"
: >"$root/stub.log"
printf '%s\n' standalone >"$root/wt-queue"
WORKSTATION_FLAKE=$fl "$shim" fleet >/dev/null 2>&1 || fail 'fleet on a logged-in node must succeed'
grep -q 'whiptail --yesno' "$root/stub.log" && fail 'a logged-in node must skip the tailscale question'
[ "$(fleet_state)" = 'false false' ] || fail 'the menu answer must land without the tailscale question'
rm -f "$root/ts-online"
machine "$fl" "$template"
rc=0
WORKSTATION_FLAKE=$fl "$shim" fleet >/dev/null 2>"$root/err" || rc=$?
[ "$rc" = 2 ] || fail "fleet on a template machine must exit 2 (got $rc)"
grep -q 'workstation init' "$root/err" || fail 'the refusal must name workstation init'

echo "$progname: OK (dispatch, resolution order, delegation, fail-closed, selection, init, peers, switch-checkout and fleet paths all hold)"
