---
name: lazyvim
description: Maintains this repository's cross-platform engine-owned workstation monorepo, host packages, Neovim profile, tmux setup, and Pi resources. Use when changing, testing, applying, or releasing this setup.
---

# Manage Workstation Monorepo

## Start

1. Locate the whole Git root containing sibling `workstation/` and `chezmoi/`:
   use `git rev-parse --show-toplevel` in a checkout, otherwise inspect the canonical
   `~/.local/bin/workstation` link. Never use chezmoi source-path or a root marker.
   Stop if `~/.local/share/workstation` is a legacy payload rather than a clone.
2. Read root and nearer `AGENTS.md` files, including their mandatory Backlog CLI
   workflow. Run `git status --short`; preserve unrelated work.
3. Resolve the following repository references from that root, not this skill's
   deployed directory:

| Work | Reference |
| --- | --- |
| Install/daily commands | `README.md` |
| Packages, lifecycle, Pi verification contracts | `docs/capabilities.md` |
| File backend, removals, guarded cutover | `docs/chezmoi.md` |
| Versions, checksums/integrity, pin generation | `docs/tools.md` |
| Editor profile/locks or tmux | `docs/nvim.md`, `docs/tmux.md` |
| Isolation and acceptance gates | `docs/testing.md` |

## Work safely

- Edit repository source only, never deployed targets. Use managed pinned tools
  and the public `workstation` lifecycle; do not overwrite legacy payloads or
  remove live clones. Real apply/cutover needs separate authorization.
- For secret-reference or vault work, ask the user to invoke `/skill:secrets`
  explicitly before entering that workflow. Do not invoke it on their behalf or
  retrieve secret values; `docs/secrets.md` owns host-authentication guidance.
- For long-running/interactive work, use a dedicated project tmux pane/window
  when available and useful. Do not assume a target or introduce tmux for a simple
  one-shot command.
- Commit or push only when requested.

## Check and hand off

Run `sh .github/scripts/check.sh`. Never run fixtures directly against an applied
home: they write fake Node/npm state. Follow `docs/testing.md` for private roots,
individual shell checks and real integration authorization. Audit full source
before a backend render; dry-run is not a sandbox. Report actual failures and
unrun acceptance gates rather than treating synthetic checks as deployment proof.
Confirm clean status after requested commits.

Before editing skills, read pinned installed Pi `docs/skills.md` and relevant
linked guidance. Retain valid name/description frontmatter and nested `SKILL.md`
discovery under `~/.pi/agent/skills/`; relative resource links resolve from the
skill directory. `pi-skills` owns actual discovery verification. Notifier
manifest/unit tests do not establish real extension discovery/reload acceptance;
follow the separate required gate in `docs/capabilities.md`.
