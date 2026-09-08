---
id: TASK-30
title: >-
  Remove Go subagents daemon stack; keep only web_search and subagents community
  extensions
status: Done
assignee:
  - '@operator'
created_date: '2026-09-08 15:48'
updated_date: '2026-09-08 16:17'
labels: []
dependencies: []
documentation:
  - docs/subagents.md
ordinal: 44000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Fully retire the GoAkt subagents daemon experiment and every repo-managed extension built on it. Remove the nested Go service module, its workstation packages, hosted/actor bridge extensions, tmux observer extension and skill, service unit templates, binaries, tests, and docs. After removal the only Pi extensions kept are the community packages web_search (pi-web-access) and subagents (pi-subagents), pinned and verified by the workstation lifecycle. Supersedes TASK-17 and TASK-18.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Source-managed extensions tmux-subagents, actor-client, and hosted-pi-bridge and the tmux-subagents skill are deleted from the repo
- [x] #2 Deployed stale targets are removed via .chezmoiremove (extensions, skill, binaries, config, service units, tmux-subagents app dir) and .chezmoiignore entries for deleted sources are cleaned
- [x] #3 Pi community package set managed/pinned by the repo is exactly npm:pi-web-access and npm:pi-subagents with versions and integrity in versions.json; pi-subagentura and pi-agent-browser-native are uninstalled from host settings
- [x] #4 tests/capabilities.test.lua, tests/tmux-subagents, tests/actor-client, tests/hosted-pi-bridge, CI workflow, and test-apply.sh no longer reference the removed stack and all remaining checks pass
- [x] #5 Root and scoped AGENTS.md, README, docs/index.md, docs/tools.md, docs/tmux.md, docs/capabilities.md, docs/chezmoi.md and the lazyvim skill no longer document the daemon/actor stack; docs/subagents.md and docs/architecture/subagents are removed
- [x] #6 Backlog tasks superseded by this removal are closed or archived through the backlog CLI only
- [x] #7 Workstation packages subagents and pi-tmux-subagents are removed and the catalog no longer registers them (the go toolchain package stays: the Neovim language profile requires it)
- [x] #8 versions.json drops pi_tmux_subagents, actor_client_xstate, xstate, and terminal_kit entries and keeps go and pi_subagents plus a new web_access pin
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Inventory every reference to the Go daemon stack (grep sweep; separate 'refactor' false positives from real 'actor' hits)
2. Delete source: services/subagents/, packages/{go,subagents,pi-tmux-subagents}, extensions {tmux-subagents,actor-client,hosted-pi-bridge}, skill tmux-subagents, service unit templates, workstation-tmux-subagents launcher, private_subagents config template
3. Update catalog.lua, versions.json (drop go/pi_tmux_subagents/actor_client_xstate/xstate/terminal_kit; add pi_web_access pin), packages/pi-subagents to pin pi-web-access too
4. Update .chezmoiremove with stale deployed targets and prune .chezmoiignore
5. Update tests/capabilities.test.lua; delete tests/{tmux-subagents,actor-client,hosted-pi-bridge}
6. Update CI workflow, .github/scripts/test-apply.sh, README, root/scoped AGENTS.md, docs (index, tools, tmux, capabilities, chezmoi), delete docs/subagents.md + docs/architecture/subagents/, update lazyvim SKILL.md
7. Run all fast checks (lua tests, stylua, git diff --check, chezmoi dry-run apply, test-apply.sh if usable)
8. Host cleanup: uninstall pi-subagentura and pi-agent-browser-native, remove deployed extensions/skill/binaries/units, ensure pi-web-access+pi-subagents pinned; then chezmoi apply
9. Close/archive superseded backlog tasks (TASK-17, TASK-18, and other daemon/actor tasks) via CLI
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Removed services/subagents Go module, packages subagents + pi-tmux-subagents, extensions tmux-subagents/actor-client/hosted-pi-bridge, tmux-subagents skill, service unit templates, private subagents config, workstation-tmux-subagents launcher, and the three mirrored test suites. Added packages/pi-web-access pinning npm:pi-web-access@0.17.1 with registry integrity; catalog now registers 11 packages. Added run_once_before_15-retire-subagents-service.sh to stop/disable the retired service; .chezmoiremove covers all stale deployed targets; dropped the now-dead CHEZMOI_WORKING_TREE export. Updated CI (subagents job and tmux-subagents lint steps removed), test-apply.sh, README, root/scoped AGENTS.md files, docs (index, tools, tmux, capabilities, chezmoi), and the lazyvim skill. Kept the go toolchain package because the Neovim language profile requires it. Host cleanup done: pi-subagentura and pi-agent-browser-native uninstalled, service disabled, stale binaries/config/extensions removed by apply; full verify lifecycle passes. Archived 26 superseded daemon/actor backlog tasks.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Removed the entire Go subagents daemon stack: services/subagents module, workstation packages subagents and pi-tmux-subagents, source-managed extensions tmux-subagents/actor-client/hosted-pi-bridge, the tmux-subagents skill, service-manager templates, private daemon config, launcher, and mirrored test suites. The repo now pins exactly two Pi community extensions — npm:pi-subagents@0.56.0 and npm:pi-web-access@0.17.1 (new packages/pi-web-access) — with versions and registry integrity in versions.json; pi-subagentura and pi-agent-browser-native were uninstalled from the host and stale deployed targets removed through .chezmoiremove plus a one-shot service-retirement script. The go toolchain package stays because the Neovim language profile requires it. Docs, AGENTS files, CI, and the lazyvim skill no longer reference the stack; 26 superseded backlog tasks archived via CLI. Verified with nvim -l tests/capabilities.test.lua, stylua --check, git diff --check, chezmoi scratch dry-run, a full .github/scripts/test-apply.sh scratch-home run ending in verify complete (linux), and the live-host verify lifecycle.
<!-- SECTION:FINAL_SUMMARY:END -->
