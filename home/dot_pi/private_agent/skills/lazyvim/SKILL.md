---
name: lazyvim
description: Maintains this repository's cross-platform chezmoi-managed workstation monorepo, host packages, Neovim profile, tmux setup, and Pi resources. Use when changing, testing, applying, or releasing this setup.
---

# Manage Workstation Monorepo

## Start

1. Locate the source root. Use the current Git root when it contains `.chezmoiroot`; otherwise run `chezmoi source-path`.
2. Read the root `AGENTS.md` and every nearer `AGENTS.md` for files being changed.
3. Read `docs/chezmoi.md` before changing apply behavior and `docs/capabilities.md` before changing lifecycle code.
4. Run `git status --short`. Preserve unrelated work.

## Ownership

| Change | Owner |
| --- | --- |
| Downloaded host tool | `home/.chezmoiexternals/` and `workstation/versions.json` |
| Combined capability and lifecycle behavior | `packages/<name>/` |
| Package ordering and registration | `workstation/catalog.lua` |
| Generic validation, graph, materialization, dispatch | `workstation/core/` |
| Host-specific package behavior | Package-local backend |
| Neovim language support | `home/dot_config/nvim/lua/languages/profile.lua` |
| Pi skill | `home/dot_pi/private_agent/skills/<name>/SKILL.md` |
| Source-managed Pi extension | `home/dot_pi/private_agent/extensions/<name>/`; owning workstation package verifies discovery and reload contract |
| Registry Pi extension package | Owning workstation package; exact version and integrity in `versions.json` |
| Secret reference or vault workflow | `/skill:secrets`; `LazyVIM` vault only |
| Deployed target removal | `home/.chezmoiremove` |

`workstation.app` is the composition root. Each package is registered once and returns one combined contribution. Core modules must not import the catalog, packages, or Neovim.

## Workflow

1. Edit repository source state, not deployed targets.
2. Keep version, URL, checksum or registry integrity, verification, and tool documentation in one change.
3. Add a package once to `workstation/catalog.lua` and add dependency-order tests.
4. Keep lifecycle handlers idempotent and package-local.
5. Use chezmoi commands as the public workflow; do not add apply or sync wrappers.
6. Let post-apply scripts run `setup` followed by `sync`.
7. Delegate secret-reference and 1Password work to `/skill:secrets`; never retrieve secret values directly.
8. When tmux is available and work is long-running, interactive, or benefits from parallel observation, use a dedicated project window or pane so commands survive and remain inspectable. Do not introduce tmux for simple one-shot commands, assume an existing target, or require it on unsupported hosts.
9. Prefer this repository's managed tools and documented chezmoi lifecycle over host-global alternatives.
10. Commit or push only when requested.

## Checks

Run all available checks relevant to the change:

```bash
nvim -l tests/capabilities.test.lua
npm ci --omit=dev --ignore-scripts --prefix home/dot_pi/private_agent/extensions/tmux-subagents
find tests/tmux-subagents -name '*.test.ts' -print0 | xargs -0 node --test
stylua --check --config-path .stylua.toml home/dot_local/share/workstation home/dot_config/nvim tests
git diff --check
chezmoi --source "$PWD" --destination "$(mktemp -d)" apply --dry-run
```

For provisioning or host-specific changes, run a full scratch-home apply and the workstation CLI `verify` lifecycle on each affected host. Confirm the working tree is clean after commits.
