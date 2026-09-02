---
id: TASK-18
title: Remove tmux-subagents after workstation extension supersession
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 02:38'
labels: []
dependencies:
  - TASK-17
  - TASK-6
references:
  - home/dot_pi/private_agent/extensions/tmux-subagents
  - home/dot_local/share/workstation/packages/pi-tmux-subagents/init.lua
  - tests/tmux-subagents
priority: high
type: chore
ordinal: 18000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Remove `tmux-subagents` only after the workstation extension demonstrably supersedes it. The workstation extension is the distributed-agent product surface: it ships owned actor discovery, asynchronous task/completion messaging, topic-backed status, durable reconnect/replay, frontend projections, and supported observation/control UX. Removal includes source, managed lifecycle registration, tests, documentation, dependency pins, and deployed-file cleanup.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 End-to-end evidence proves the workstation extension provides every retained distributed-agent and observation behavior required before cutover
- [ ] #2 The `tmux-subagents` extension, its managed lifecycle package, tests, locks, version/integrity entries, documentation, and package-catalog references are removed
- [ ] #3 Previously deployed `tmux-subagents` files are retired through the appropriate chezmoi removal inventory
- [ ] #4 Repository and scratch-apply gates pass with no runtime, documentation, or configuration dependency on `tmux-subagents`
<!-- AC:END -->
