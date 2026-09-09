---
name: lazyvim
description: Maintains this repository's cross-platform engine-owned workstation monorepo, host packages, Neovim profile, tmux setup, and Pi resources. Use when changing, testing, applying, or releasing this setup.
---

# Manage Workstation Monorepo

## Start

1. Locate the whole Git source root containing sibling `workstation/` and `chezmoi/`. From a checkout use `git rev-parse --show-toplevel`; otherwise inspect the canonical `~/.local/bin/workstation` link to its repo-native launcher. Never rely on chezmoi source-path or a source-root marker. Stop if the existing `~/.local/share/workstation` is a legacy deployed payload rather than a clone.
2. Read the root `AGENTS.md` and every nearer `AGENTS.md` for files being changed.
3. Read `docs/chezmoi.md` before changing apply behavior and `docs/capabilities.md` before changing lifecycle code.
4. Run `git status --short`. Preserve unrelated work.

## Ownership

| Change | Owner |
| --- | --- |
| Downloaded host tool | Owning `workstation/packages/` setup and `workstation/versions.json`; runtime/backend are bootstrap-owned |
| Combined capability and lifecycle behavior | `workstation/packages/<name>/` |
| Package ordering and registration | `workstation/lua/workstation/catalog.lua` |
| Generic validation, graph, materialization, dispatch | `workstation/lua/workstation/core/` |
| Host-specific package behavior | Package-local backend |
| Neovim language support | `chezmoi/dot_config/nvim/lua/languages/profile.lua` |
| Pi skill | `chezmoi/dot_pi/private_agent/skills/<name>/SKILL.md` |
| Source-managed Pi extension | `chezmoi/dot_pi/private_agent/extensions/<name>/`; owning workstation package verifies discovery and reload contract |
| Registry Pi extension package | Owning workstation package; exact version and integrity in `versions.json` |
| Secret reference or vault workflow | `/skill:secrets`; `Workstation` vault only |
| Deployed target removal | `chezmoi/.chezmoiremove` |

`workstation.app` is the composition root. Each package is registered once and returns one combined contribution. Core modules must not import the catalog, packages, or Neovim.

## Workflow

1. Edit repository source state, not deployed targets.
2. Keep version, URL, checksum or registry integrity, verification, and tool documentation in one change.
3. Add a package once to `workstation/lua/workstation/catalog.lua` and add dependency-order tests.
4. Keep lifecycle handlers idempotent and package-local.
5. Use `workstation` as the sole public lifecycle. Fresh install is repo launcher `bootstrap` then installed launcher `apply`, `sync`, `verify`. Bootstrap prepares pinned runtime/backend and a conflict-safe public symlink; no Node/system-Neovim dependency.
6. Apply owns guarded real-account retirement (never scratch), explicit file-backend materialization, Node pin/PATH refresh and setup. Sync is separate. Direct setup before the first apply rejects a missing Node pin before Node/nvm provisioning. Update checks pull then freshly launched bootstrap/apply/sync/verify; diff previews files only. Never add compatibility aliases or imaginary dry-run flags.
7. Delegate secret-reference and 1Password work to `/skill:secrets`; never retrieve secret values directly.
8. When tmux is available and work is long-running, interactive, or benefits from parallel observation, use a dedicated project window or pane so commands survive and remain inspectable. Do not introduce tmux for simple one-shot commands, assume an existing target, or require it on unsupported hosts.
9. Prefer managed pinned tools and engine lifecycle over host-global alternatives. Git/tmux/Bash/build/font prerequisites are user/CI-owned; never install OS prerequisites from lifecycle code. Follow guarded operator cutover in `docs/chezmoi.md`; never overwrite legacy payloads or remove a live clone.
10. Commit or push only when requested.

## Checks

Run all available checks relevant to the change:

```bash
for suite in tests/*.test.lua; do "$HOME/.local/opt/nvim/bin/nvim" -l "$suite" || exit; done
"$HOME/.local/opt/nvim/bin/nvim" -l .github/scripts/syntax.lua
"$HOME/.local/opt/nvim/bin/nvim" -l workstation/bootstrap/generate.lua --check
stylua --check --config-path .stylua.toml workstation chezmoi/dot_config/nvim tests .github/scripts
git diff --check
```

Check every shell separately with `sh -n` and available ShellCheck. For authorized real integration use `.github/scripts/test-apply.sh <new-absolute-scratch-home>` outside the real home/source: bootstrap → apply → sync → all fast checks/format → verify. This downloads real assets; offline copied-source fixtures are not platform acceptance. Inspect the source before the isolated file-only render in `docs/chezmoi.md`; dry-run alone is not a sandbox. Keep auth/session/provider state private and never source login profiles for scratch checks. Confirm the working tree is clean after requested commits.

When editing skills, consult the pinned installed Pi `docs/skills.md`: managed global resources deploy under `~/.pi/agent/skills/`, nested `SKILL.md` discovery uses valid name/description frontmatter, and relative resource paths resolve from the skill directory. Edit repository skills only, never deployed skills; `pi-skills` owns discovery verification.
