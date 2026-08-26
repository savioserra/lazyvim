---
name: manage-lazyvim-workstation
description: Maintains this repository's cross-platform chezmoi-managed LazyVim workstation, capabilities, host tools, Neovim profile, tmux setup, and Pi resources. Use when changing, testing, applying, or releasing this setup.
---

# Manage LazyVim Workstation

## Start

1. Locate the source root. Use the current Git root when it contains `.chezmoiroot`; otherwise run `chezmoi source-path`.
2. Read the root `AGENTS.md` and every nearer `AGENTS.md` for files being changed.
3. Read `docs/chezmoi.md` before changing apply behavior and `docs/capabilities.md` before changing lifecycle code.
4. Run `git status --short`. Preserve unrelated work.

## Ownership

| Change | Owner |
| --- | --- |
| Downloaded host tool | `home/.chezmoiexternals/` and `versions.json` |
| Capability policy | `setup/capabilities/` |
| Setup, sync, or verification behavior | `setup/features/` |
| Generic ordering and dispatch | `setup/runtime/` |
| Host-specific feature behavior | Feature-local backend |
| Neovim language support | `home/dot_config/nvim/lua/languages/profile.lua` |
| Pi skill | `home/dot_pi/agent/skills/<name>/SKILL.md` |
| Deployed target removal | `home/.chezmoiremove` |

`setup.app` is the composition root. Capability declarations contain data only. Runtime modules must not import capabilities or features.

## Workflow

1. Edit repository source state, not deployed targets.
2. Keep version, URL, checksum or registry integrity, verification, and tool documentation in one change.
3. Add capabilities to both catalogs and add dependency-order tests.
4. Keep lifecycle handlers idempotent.
5. Use chezmoi commands as the public workflow; do not add apply or sync wrappers.
6. Let post-apply scripts run `setup` followed by `sync`.
7. Use the existing psmux Linux VPS pane for remote Linux work when the user requests it; do not open a separate SSH path.
8. Commit or push only when requested.

## Checks

Run all available checks relevant to the change:

```bash
nvim -l tests/capabilities.test.lua
stylua --check --config-path .stylua.toml home/dot_local/share/lazyvim home/dot_config/nvim tests
git diff --check
chezmoi --source "$PWD" --destination "$(mktemp -d)" apply --dry-run
```

For provisioning or host-specific changes, run a full scratch-home apply and `run.lua verify` on each affected host. Confirm the working tree is clean after commits.
