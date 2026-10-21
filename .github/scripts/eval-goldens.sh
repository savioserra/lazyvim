#!/bin/sh
# Eval-goldens: the nix walker's report must byte-match the committed
# golden at HEAD. This is the drift guard between the package tree's two
# readers (the Elixir engine's catalog and the nix walker): a payload
# edit without a deliberate golden re-record reds here.
#
# The committed tree is extracted with `git archive $rev` and evaluated
# as a path flake — identical semantics on checkouts, worktrees and CI
# (no git-dir assumptions). Runs when nix is available directly, else
# inside the pinned nix container when docker is available (volume-cached
# store), else skips loudly — the macOS CI leg has neither and stays green.
set -eu
repo_root=$(CDPATH='' cd -P "$(dirname "$0")/../.." && pwd -P)
cd "$repo_root"

golden=tests/nix/goldens/eval-report.json
report_attr='evalReport.x86_64-linux'

if [ ! -f "$golden" ]; then
	printf 'eval-goldens: no golden at %s; skipping (pre-substrate tree)\n' "$golden" >&2
	exit 0
fi

head_rev=$(git -C "$repo_root" rev-parse HEAD)
tree=$(mktemp -d)
out=$(mktemp)
trap 'rm -rf "$tree" "$out"' EXIT
git -C "$repo_root" archive "$head_rev" | tar -x -C "$tree"

if command -v nix >/dev/null 2>&1; then
	NIX_CONFIG="extra-experimental-features = nix-command flakes" \
		nix eval --json "path:$tree#$report_attr" >"$out"
elif command -v docker >/dev/null 2>&1; then
	docker run --rm -v "$tree":/ws:ro -v ws-nixstore:/nix \
		nixos/nix:2.35.3 sh -c "
			NIX_CONFIG='extra-experimental-features = nix-command flakes'
			export NIX_CONFIG
			HOME=/tmp/nixhome
			mkdir -p \"\$HOME\"
			nix eval --json 'path:/ws#$report_attr'" >"$out"
else
	printf 'eval-goldens: neither nix nor docker available; skipping (required in the Linux CI job)\n' >&2
	exit 0
fi

if diff -u "$golden" "$out"; then
	printf 'eval-goldens: OK (walker report matches the golden at %s)\n' "$head_rev"
else
	printf 'eval-goldens: DRIFT — the walker report no longer matches %s; re-record deliberately (tests/nix/goldens) and name the payload change\n' "$golden" >&2
	exit 1
fi
