#!/bin/sh
# The check matrix: the nixpkgs-native substrate is declared state, so the
# matrix is static source gates plus the nix eval read gate. The Elixir
# engine battery (mix test, doclint, the release boot smoke, the locale
# guard) retired with the engine; verification beyond this matrix is
# behavioral — the docker-nix acceptance (closures) and the container E2E
# (activation + consumers), owned by docs/testing.md.
#
# Ordering: the identity gate runs first (cheap source grep), then the
# engine-free gate (no Elixir module token survives anywhere in the tree),
# then the shell checks, then the nix eval reads (skipped with a loud note
# where nix is absent — the docker acceptance owns them there).
set -eu
repo_root=$(CDPATH='' cd -P "$(dirname "$0")/../.." && pwd -P)
cd "$repo_root"
fail=0

step() { printf '\n== %s\n' "$1"; }

step 'nix identity gate (the repo is a template: identity is captured at install time only — hosts/identity.nix, uncommitted on real machines)'
# A gate may only pass on a real no-match (git grep exit 1): a tooling
# failure (exit 128 — not a checkout, a bad pathspec) fails CLOSED, never
# reads as "no match".
gate() {
	# gate <name> <hit message> <grep args...>
	name=$1
	hitmsg=$2
	shift 2
	rc=0
	"$@" || rc=$?
	case $rc in
	1) return 0 ;;
	0)
		fail=1
		"$@"
		printf '%s\n' "$hitmsg" >&2
		;;
	*)
		fail=1
		printf '%s: %s exited %s — failing closed (a gate only passes on a real no-match)\n' "$name" "$1" "$rc" >&2
		;;
	esac
}
gate 'identity gate' \
	'identity gate: hardcoded personal identity in the tracked tree — the legs are templates; hosts/identity.nix (captured by workstation init, kept uncommitted) is the only identity surface' \
	git grep -iE 'savio|shyylol' -- . ':(exclude).github/scripts/check.sh'

step 'engine-free gate (the Elixir plane stays gone: no engine module token anywhere in the tree)'
# the token is assembled at runtime so this gate's own source never
# carries it — the tree-wide grep must come back EMPTY
engine_module_token='def''module'
gate 'engine-free gate' \
	'engine-free gate: the Elixir engine retired; this tree is nixpkgs-native (docs/endgame.md)' \
	git grep -n "$engine_module_token" -- .

step 'shell syntax (sh -n) and ShellCheck when available'
{
	find bin modules .github/scripts tests hosts -type f \( -name '*.sh' -o -name 'workstation' \) -print
} | while IFS= read -r file; do
	sh -n "$file" || exit 1
	if command -v shellcheck >/dev/null 2>&1; then
		shellcheck -s sh "$file" || exit 1
	fi
done || fail=1
if ! command -v shellcheck >/dev/null 2>&1; then
	printf 'ShellCheck unavailable here; required in the Linux CI job.\n' >&2
fi

step 'nixfmt-rfc-style gate (RFC 166)'
if command -v nixfmt >/dev/null 2>&1; then
	{ find flake.nix modules nix hosts tests -type f -name '*.nix' -print; } |
		xargs nixfmt --check || fail=1
else
	printf 'nixfmt unavailable here; the nix CI job owns the format gate.\n' >&2
fi

step 'launcher shim dispatch gate (stubbed nix, stubbed switch driver)'
sh .github/scripts/shim-dispatch.sh || fail=1

step 'nix eval read gate (#workstation.report.<verb> answers)'
if command -v nix >/dev/null 2>&1; then
	for verb in status plan capabilities; do
		nix --extra-experimental-features 'nix-command flakes' \
			eval --json ".#workstation.report.$verb" >/dev/null || fail=1
	done
	printf 'status counts: '
	nix --extra-experimental-features 'nix-command flakes' \
		eval --json .#workstation.report.status.counts
else
	printf 'nix unavailable here; the docker acceptance owns the eval gate (docs/testing.md).\n' >&2
fi

step 'whitespace (git diff --check)'
git diff --check || fail=1

[ "$fail" -eq 0 ] || { printf '\ncheck.sh: FAILED\n' >&2; exit 1; }
printf '\ncheck.sh: OK\n'
