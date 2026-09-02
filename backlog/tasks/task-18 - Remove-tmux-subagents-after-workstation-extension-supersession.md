---
id: TASK-18
title: >-
  Remove pi-subagents and tmux-subagents after workstation extension
  supersession
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 02:38'
updated_date: '2026-09-02 02:41'
labels: []
dependencies:
  - TASK-17
  - TASK-6
references:
  - home/dot_pi/private_agent/extensions/tmux-subagents
  - home/dot_local/share/workstation/packages/pi-tmux-subagents/init.lua
  - tests/tmux-subagents
  - home/dot_local/share/workstation/packages/pi-subagents/init.lua
  - home/dot_pi/private_agent/skills/tmux-subagents/SKILL.md
  - home/dot_local/share/workstation/versions.json
  - home/.chezmoiexternals
  - home/.chezmoiremove
priority: high
type: chore
ordinal: 18000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Remove both the managed upstream `pi-subagents` Pi package and `tmux-subagents` only after the workstation extension demonstrably supersedes them. The workstation extension is the distributed-agent product surface: it ships owned actor discovery, asynchronous task/completion messaging, topic-backed status, durable reconnect/replay, frontend projections, and supported observation/control UX. Removal includes installed Pi package declarations, source-managed extension and skill, lifecycle registrations, tests, documentation, version/integrity pins, generated locks, and deployed-file cleanup.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 End-to-end evidence proves the workstation extension provides every retained distributed-agent, workflow, and observation behavior required before cutover from both legacy Pi packages
- [ ] #2 The managed `pi-subagents` package and `tmux-subagents` extension/skill, lifecycle packages, tests, locks, version/integrity entries, documentation, and catalog references are removed
- [ ] #3 Previously deployed `pi-subagents` and `tmux-subagents` files are retired through the appropriate chezmoi removal inventory
- [ ] #4 Repository and scratch-apply gates pass with no runtime, documentation, configuration, skill, or package dependency on either legacy package
<!-- AC:END -->
