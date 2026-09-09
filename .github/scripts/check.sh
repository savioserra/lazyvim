#!/bin/sh
# Run after sync: StyLua belongs to the locked Mason profile, not bootstrap.
set -eu
repo_root=$(CDPATH='' cd -P "$(dirname "$0")/../.." && pwd -P)
cd "$repo_root"
installed_home=$(CDPATH='' cd -P "$HOME" && pwd -P)
nvim=$installed_home/.local/opt/nvim/bin/nvim
stylua=$installed_home/.local/share/nvim/mason/bin/stylua
[ -x "$nvim" ] && [ -x "$stylua" ]
isolate=$repo_root/.github/scripts/test-home.sh
# Locate the trusted installed backend for the real-render suite. The canonical
# pinned install wins; a retained evidence extraction is accepted and its
# ACTUAL version is reported by the suite, never confused with the pin.
backend=$installed_home/.local/opt/chezmoi/bin/chezmoi
if [ ! -x "$backend" ]; then
	for candidate in "$installed_home"/.local/opt/chezmoi-*/chezmoi; do
		[ -x "$candidate" ] && backend=$candidate && break
	done
fi
[ -x "$backend" ] || { printf 'trusted chezmoi backend not found\n' >&2; exit 1; }
for suite in tests/*.test.lua; do
	# The real-check regression needs the frozen formatter too; no tool paths
	# are rediscovered from the new fixture HOME.
	sh "$isolate" "$nvim" -l "$suite" "$stylua" "$backend"
done
sh "$isolate" "$nvim" -l .github/scripts/syntax.lua
sh "$isolate" "$nvim" -l workstation/bootstrap/generate.lua --check
sh "$isolate" "$stylua" --check --config-path .stylua.toml workstation chezmoi/dot_config/nvim tests .github/scripts
# Each file requires its own sh -n invocation. These modifiers are literal shell
# (no template expressions); checking them does not execute their output.
find workstation chezmoi .github/scripts -type f \( -name '*.sh' -o -name 'workstation' -o -name 'modify_*.tmpl' \) -print |
	while IFS= read -r file; do
		sh "$isolate" sh -n "$file"
		if command -v shellcheck >/dev/null 2>&1; then
			sh "$isolate" shellcheck -s sh "$file"
		fi
	done
if ! command -v shellcheck >/dev/null 2>&1; then
	printf 'ShellCheck unavailable here; required in the Linux CI job.\n' >&2
fi
sh "$isolate" git diff --check
