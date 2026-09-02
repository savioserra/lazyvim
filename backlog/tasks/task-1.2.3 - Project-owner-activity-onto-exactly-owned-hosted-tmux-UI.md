---
id: TASK-1.2.3
title: Project owner activity onto exactly owned hosted tmux UI
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 05:40'
updated_date: '2026-09-02 05:40'
labels: []
dependencies:
  - TASK-1.2.1
  - TASK-21
references:
  - services/subagents/internal/actors/hosted_pi_runtime.go
  - services/subagents/internal/hostedpi/runtime.go
  - docs/architecture/subagents/ACTOR-UX-DESIGN-SYSTEM.md
parent_task_id: TASK-1.2
priority: high
type: feature
ordinal: 32000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Bind each HostedPiRuntimeActor to its owner-private topic and render sanitized identity/lifecycle/activity onto exactly owned tmux title/border/status resources after complete ownership validation.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Runtime subscribes and replays only its owner identity/activity stream with epoch/revision fencing and no actor-list polling or terminal scraping
- [ ] #2 Before every effect the complete daemon/runtime/incarnation/tmux server/session/window/pane/process/TTY ownership tuple is revalidated
- [ ] #3 Only exactly owned title, border, or status metadata is changed; foreign, adopted, replaced, or indeterminate panes are untouched and no pane body/send-keys/respawn operation exists
- [ ] #4 Renderer or tmux failure updates visibility health only and cannot modify authoritative identity, lifecycle, activity, routing, or tasks
- [ ] #5 Tests cover set/clear/replay, stale frames, replacement attacks, tmux disappearance, narrow bounds, redaction, restart adoption, and no foreign mutation
<!-- AC:END -->
