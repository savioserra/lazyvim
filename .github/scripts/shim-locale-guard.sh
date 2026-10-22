#!/bin/sh
# Shim UTF-8 locale guard gate. The POSIX shim must keep every engine VM
# launch UTF-8-safe: a bare box often runs LANG= / LC_CTYPE=POSIX and the VM
# falls back to latin1, which Elixir documents as a malfunction risk for
# non-ASCII names (the payload ships dotfiles and font names). Each case
# runs the REAL checkout shim inside its own test-home.sh process boundary
# (env -i: no ambient LANG/LC_* crosses) against a STUB release at the exact
# path the shim execs, so the guard's decisions are observed through the
# launch environment the stub records and the shim's own stderr banner —
# no release tarball and no daemon. A stub locale(1) first on the fixture
# PATH pins the effective charmap; a minimal PATH without locale(1) covers
# hosts that lack the binary entirely.
#
# Contract asserted (the launcher's locale-guard decision body):
#   1. charmap UTF-8 -> nothing exported, no banner.
#   2. non-UTF-8 charmap, nothing set, no C.utf8 on the host -> the engine
#      gains a leading +fnu (existing ELIXIR_ERL_OPTIONS preserved after the
#      prefix) and the banner advises a real UTF-8 locale.
#   3. non-UTF-8 charmap, no locale variable set at all, C.utf8 available
#      -> last-resort LANG=C.UTF-8 default, no +fnu needed, honest fallback
#      banner (a default is a fallback, not a fix for the host).
#   4. LC_CTYPE explicitly POSIX -> respected over any default: +fnu, LANG
#      untouched.
#   5. no locale(1) binary -> environment-only judgment: a UTF-8 name in
#      LC_ALL passes clean; nothing set falls back to +fnu.
set -eu
repo_root=$(CDPATH='' cd -P "$(dirname "$0")/../.." && pwd -P)

scratch=$(mktemp -d "${TMPDIR:-/tmp}/shim-locale-guard.XXXXXX")
cleanup() { rm -rf "$scratch"; }
trap cleanup 0

fail() { echo "shim-locale-guard: FAIL: $*" >&2; exit 1; }

# Stub locale(1): the fixture controls the answers through
# $HOME/.locale-stub-config, "<charmap>|<locale -a body, \n escapes>";
# an empty field fails like a broken locale install would.
cat > "$scratch/locale" <<'EOF'
#!/bin/sh
cfg=$(cat "$HOME/.locale-stub-config" 2>/dev/null) || exit 1
charmap=${cfg%%|*}
loclist=${cfg#*|}
case ${1:-} in
charmap)
	[ -n "$charmap" ] || exit 1
	printf '%s\n' "$charmap"
	;;
-a)
	[ -n "$loclist" ] || exit 1
	printf '%b\n' "$loclist"
	;;
*)
	exit 1
	;;
esac
EOF
chmod 0755 "$scratch/locale"

# Stub engine release at the path the shim execs: records the launch
# environment the shim handed over, then exits clean.
optbin=$scratch/opt/workstation/bin
mkdir -p "$optbin"
cat > "$optbin/workstation" <<'EOF'
#!/bin/sh
{
	printf 'LANG=%s\n' "${LANG-unset}"
	printf 'LC_ALL=%s\n' "${LC_ALL-unset}"
	printf 'LC_CTYPE=%s\n' "${LC_CTYPE-unset}"
	printf 'ELIXIR_ERL_OPTIONS=%s\n' "${ELIXIR_ERL_OPTIONS-unset}"
} > "$HOME/locale-guard-env-dump"
EOF
chmod 0755 "$optbin/workstation"

# Minimal PATH for the no-locale(1) cases: every tool the harness and the
# shim need, and deliberately no locale binary, so the guard's env-only
# fallback is exercised deterministically.
minbin=$scratch/minbin
mkdir -p "$minbin"
for tool in sh env mktemp rm cat cp mkdir sed grep uname readlink dirname basename chmod; do
	ln -s "$(command -v "$tool")" "$minbin/$tool"
done

run_case() {
	name=$1 path_mode=$2 charmap=$3 loclist=$4 preset=$5
	want_lang=$6 want_ero=$7 want_banner=$8
	case "$path_mode" in
	stub) fixture_path=$scratch:$PATH ;;
	minimal) fixture_path=$minbin ;;
	*) fail "unknown path mode: $path_mode" ;;
	esac
	result=$(PATH=$fixture_path sh "$repo_root/.github/scripts/test-home.sh" \
		sh -eu -c '
			fail() { echo "shim-locale-guard: FAIL ($1): $2" >&2; exit 1; }
			case_name=$1 repo=$2 stub_release=$3 charmap=$4 loclist=$5 preset=$6
			want_lang=$7 want_ero=$8 want_banner=$9
			printf "%s|%s" "$charmap" "$loclist" > "$HOME/.locale-stub-config"
			opt=$HOME/.local/opt/workstation/bin
			mkdir -p "$opt"
			cp "$stub_release" "$opt/workstation"
			if [ -n "$preset" ]; then eval "export $preset"; fi
			if ! "$repo/workstation/bin/workstation" diff --home "$HOME" \
				>"$HOME/shim.out" 2>"$HOME/shim.err"; then
				cat "$HOME/shim.err" >&2
				fail "$case_name" "the shim did not reach the stub release"
			fi
			[ -f "$HOME/locale-guard-env-dump" ] ||
				fail "$case_name" "the stub release never recorded the launch environment"
			dump=$(cat "$HOME/locale-guard-env-dump")
			lang=$(printf "%s\n" "$dump" | sed -n "s/^LANG=//p")
			ero=$(printf "%s\n" "$dump" | sed -n "s/^ELIXIR_ERL_OPTIONS=//p")
			[ "$lang" = "$want_lang" ] ||
				fail "$case_name" "LANG: got [$lang], want [$want_lang]"
			[ "$ero" = "$want_ero" ] ||
				fail "$case_name" "ELIXIR_ERL_OPTIONS: got [$ero], want [$want_ero]"
			case "$want_banner" in
			none)
				if [ -s "$HOME/shim.err" ]; then
					fail "$case_name" "unexpected stderr: [$(cat "$HOME/shim.err")]"
				fi
				;;
			fallback)
				grep -q "defaulting LANG=C.UTF-8" "$HOME/shim.err" ||
					fail "$case_name" "no honest fallback banner: [$(cat "$HOME/shim.err")]"
				;;
			fnu)
				grep -q "ELIXIR_ERL_OPTIONS=+fnu" "$HOME/shim.err" ||
					fail "$case_name" "no +fnu banner: [$(cat "$HOME/shim.err")]"
				;;
			*)
				fail "$case_name" "unknown banner expectation: $want_banner"
				;;
			esac
			printf "case-ok\n"
		' sh "$name" "$repo_root" "$optbin/workstation" \
			"$charmap" "$loclist" "$preset" "$want_lang" "$want_ero" "$want_banner") ||
		fail "$name: fixture failed"
	[ "$result" = case-ok ] || fail "$name: unexpected fixture output: $result"
}

# 1. A real UTF-8 locale: nothing to do.
run_case utf8_charmap_is_clean stub UTF-8 'C\nPOSIX' '' unset unset none
# 2. POSIX charmap, nothing set, no C.utf8 on the host: +fnu + honest banner.
run_case posix_charmap_falls_back_to_fnu stub ANSI_X3.4-1968 'C\nPOSIX\nen_US.iso88591' '' \
	unset +fnu fnu
run_case posix_charmap_preserves_existing_ero stub ANSI_X3.4-1968 'C\nPOSIX' \
	'ELIXIR_ERL_OPTIONS=+vc' unset '+fnu +vc' fnu
# 3. Nothing set and the glibc-builtin C.UTF-8 exists: last-resort default.
run_case nothing_set_defaults_to_cutf8 stub ANSI_X3.4-1968 'C\nC.utf8\nPOSIX' '' \
	C.UTF-8 unset fallback
run_case empty_lang_defaults_to_cutf8 stub ANSI_X3.4-1968 'C\nC.utf8\nPOSIX' 'LANG=' \
	C.UTF-8 unset fallback
# 4. An explicit LC_CTYPE=POSIX is respected, never stomped: +fnu instead.
run_case lc_ctype_posix_is_respected stub ANSI_X3.4-1968 'C\nC.utf8\nPOSIX' 'LC_CTYPE=POSIX' \
	unset +fnu fnu
# 5. No locale(1) at all: the environment alone decides.
run_case utf8_env_name_clean_without_locale minimal '' '' 'LC_ALL=en_US.UTF-8' \
	unset unset none
run_case nothing_set_without_locale_falls_to_fnu minimal '' '' '' unset +fnu fnu

echo 'shim-locale-guard: OK (UTF-8 clean pass-through, +fnu fallback, honest C.UTF-8 default, LC_CTYPE respected, locale-less hosts judged by the environment)'
