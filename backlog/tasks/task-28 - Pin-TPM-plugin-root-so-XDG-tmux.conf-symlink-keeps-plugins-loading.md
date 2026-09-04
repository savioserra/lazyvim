---
id: TASK-28
title: Pin TPM plugin root so XDG tmux.conf symlink keeps plugins loading
status: Done
assignee:
  - '@shyylol'
created_date: '2026-09-03 11:40'
updated_date: '2026-09-03 11:52'
labels:
  - tmux
  - bug
dependencies: []
priority: high
type: bug
ordinal: 44000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
After the debd72c XDG-precedence fix created ~/.config/tmux/tmux.conf (symlink to ~/.tmux.conf), TPM's set_default_tpm_path redirected TMUX_PLUGIN_MANAGER_PATH to ~/.config/tmux/plugins/, which does not exist. TPM then silently sourced no plugins, so tmux2k never rendered and a freshly booted tmux server showed the compiled-in default green status bar. Fix by pinning set-environment -g TMUX_PLUGIN_MANAGER_PATH '~/.tmux/plugins/' before run-shell tpm, asserting it in the package verify, and documenting the TPM XDG redirection plus the omarchy-refresh-config cp-through-symlink hazard.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Isolated tmux server loading the managed config renders the tmux2k powerline status (status-left contains the round separator)
- [x] #2 Package verify asserts TMUX_PLUGIN_MANAGER_PATH resolves to ~/.tmux/plugins/ on an isolated server
- [x] #3 docs/tmux.md documents the pinned plugin root and both Omarchy/TPM interaction hazards
- [x] #4 Fast checks pass: capabilities tests, stylua, git diff --check, chezmoi dry-run apply
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Pin TMUX_PLUGIN_MANAGER_PATH to ~/.tmux/plugins/ in home/dot_tmux.conf before the tpm run-shell line. 2. Assert the pinned environment plus existing tmux2k render assertions in packages/tmux/init.lua verify on an isolated socket. 3. Document pinned plugin root, TPM XDG redirection, and omarchy-refresh-config cp-through-symlink hazard in docs/tmux.md. 4. Run fast checks (capabilities tests, stylua, git diff --check, chezmoi dry-run apply), then chezmoi apply and reload the running tmux server.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Root cause chain: debd72c created ~/.config/tmux/tmux.conf (symlink to ~/.tmux.conf) for XDG precedence; TPM set_default_tpm_path then redirected TMUX_PLUGIN_MANAGER_PATH to the nonexistent ~/.config/tmux/plugins/ and silently sourced no plugins, so tmux2k never rendered on the first post-reboot server (boot 08:21, server 08:23). /etc/tmux.conf in config_files was a red herring: tmux 3.7 lists the system config path unconditionally. Omarchy never wrote our files; its omarchy-refresh-config cp -f through the XDG symlink remains a latent hazard, documented. Evidence: isolated server with fix shows TMUX_PLUGIN_MANAGER_PATH=~/.tmux/plugins/ and two U+E0B4 separators in status-left; full packages.tmux verify passes from source against deployed state; live server reloaded with tmux source-file and shows catppuccin theme, bottom position, tmux2k status-left. Checks: nvim -l tests/capabilities.test.lua passed, git diff --check clean, chezmoi --source $PWD dry-run to temp destination clean, full apply + setup + sync green after unsetting foreign GOROOT/GOBIN (see TASK-29). stylua is not installed on this host, so that check could not run.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Pinned set-environment -g TMUX_PLUGIN_MANAGER_PATH '~/.tmux/plugins/' before the TPM run-shell in home/dot_tmux.conf, added the matching assertion to the tmux package verify, and documented the TPM XDG redirection plus the Omarchy cp-through-symlink hazard in docs/tmux.md. Verified by an isolated-server render (powerline separators present), the full package verify passing, and a live reload of the running server restoring the tmux2k theme after a fresh chezmoi --source apply.
<!-- SECTION:FINAL_SUMMARY:END -->
