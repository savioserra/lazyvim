#!/bin/sh
# Run after sync: StyLua belongs to the locked Mason profile, not bootstrap.
set -eu
repo_root=$(CDPATH='' cd -P "$(dirname "$0")/../.." && pwd -P)
cd "$repo_root"
nvim=$HOME/.local/opt/nvim/bin/nvim
stylua=$HOME/.local/share/nvim/mason/bin/stylua
for suite in tests/*.test.lua; do
	"$nvim" -l "$suite"
done
"$nvim" -l .github/scripts/syntax.lua
"$nvim" -l workstation/bootstrap/generate.lua --check
"$stylua" --check --config-path .stylua.toml workstation chezmoi/dot_config/nvim tests .github/scripts
# Each file requires its own sh -n invocation. These modifiers are literal shell
# (no template expressions); checking them does not execute their output.
find workstation chezmoi .github/scripts -type f \( -name '*.sh' -o -name 'workstation' -o -name 'modify_*.tmpl' \) -print |
	while IFS= read -r file; do
		sh -n "$file"
		if command -v shellcheck >/dev/null 2>&1; then
			shellcheck -s sh "$file"
		fi
	done
if ! command -v shellcheck >/dev/null 2>&1; then
	printf 'ShellCheck unavailable here; required in the Linux CI job.\n' >&2
fi
git diff --check
