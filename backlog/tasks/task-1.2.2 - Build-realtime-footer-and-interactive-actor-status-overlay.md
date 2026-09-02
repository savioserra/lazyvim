---
id: TASK-1.2.2
title: Build realtime footer and interactive actor status overlay
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 05:40'
updated_date: '2026-09-02 05:44'
labels: []
dependencies:
  - TASK-1.2.1
  - TASK-21
references:
  - home/dot_pi/private_agent/extensions/actor-client/index.ts
  - home/dot_pi/private_agent/extensions/actor-client/projections
  - home/dot_pi/private_agent/extensions/actor-client/widgets
  - >-
    /home/shyylol/.local/opt/nvm/versions/node/v24.19.0/lib/node_modules/@earendil-works/pi-coding-agent/docs/tui.md
parent_task_id: TASK-1.2
priority: high
type: feature
ordinal: 31000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Project authenticated roster/activity frames through the existing actor-client XState root into an immediate compact footer and a bounded interactive `/actor-status` overlay. Both views consume one immutable disposable snapshot and never query actor_list for refresh.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Every accepted topic frame immediately rebuilds the compact footer with connection, display name, lifecycle, activity, pending request, and bounded overflow semantics
- [ ] #2 `/actor-status` opens a Pi TUI overlay with keyboard selection/cancel, narrow fallback, visible status details, and live rerender from the same XState snapshot while open
- [ ] #3 The overlay is read-only projection UI; it exposes no stop/control actions, credentials, principals, fences, runtime IDs, PIDs, tmux IDs, prompts, answers, or raw payloads
- [ ] #4 Unknown activity labels naturalize safely, clear removes only activity, lifecycle/activity remain separate, and stale/gapped/reconnect frames never flash older state
- [ ] #5 TUI tests cover theme invalidation, ANSI width, 20/25/49/80 columns, overlay input/focus/disposal, live update rendering, non-TUI no-op, reconnect, and no polling
- [ ] #6 Footer and overlay wording is copy-reviewed for one semantic fact per location; lifecycle/activity/pending/visibility labels are not redundantly repeated between row, detail, and footer
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Information-hierarchy correction: interactive status remains payload-free. Actual Tell/Ask content expansion belongs to TASK-1.1 private conversation/tool balloons, while TASK-1.2.2 status rows avoid redundant labels and link users to conversation history rather than leaking payloads.
<!-- SECTION:NOTES:END -->
