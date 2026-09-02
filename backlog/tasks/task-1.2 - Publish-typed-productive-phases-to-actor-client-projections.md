---
id: TASK-1.2
title: Publish dynamic activity and live actor status UI
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 02:56'
updated_date: '2026-09-02 05:40'
labels: []
dependencies: []
references:
  - docs/architecture/subagents/ACTOR-UX-DESIGN-SYSTEM.md
  - services/subagents/internal/actors/hosted_pi_runtime.go
parent_task_id: TASK-1
priority: high
type: feature
ordinal: 20000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Publish authoritative, revision-fenced dynamic activity metadata from AgentActors, including prompt-driven crew supervisors, and project it through authenticated topic-backed roster/status/UI surfaces. Activity keys and labels are supplied by the owning agent/domain at runtime; they are not central enums and are never inferred from role, lifecycle, liveness, tmux, tool output, or elapsed time. Actor-client provides immediate live footer status plus a bounded expandable interactive status view. Each hosted runtime subscribes to its owner-private projection and may update only exactly owned tmux UI.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 AgentActor publishes a typed activity envelope with opaque bounded key, optional human label/details, authoritative owner/source, epoch/revision, durable set/clear semantics, and no enumerated domain phase values
- [ ] #2 Role, lifecycle, activity, access mode, and visibility are independent facts; changing one does not synthesize or clear another, and absent activity never fabricates idle
- [ ] #3 Actor-client updates its compact footer status immediately from authenticated roster/activity topic push, rejects stale/gapped frames, and never uses actor_list polling or terminal/liveness inference
- [ ] #4 A bounded `/actor-status` interactive overlay expands the same disposable XState snapshot into selectable actor details and status reporting, updates live while open, remains keyboard accessible, and performs no authority mutation
- [ ] #5 Compact and expanded UI sanitize unknown activity keys/labels, redact all private routing/runtime/tmux/session data, remain ANSI/display-width safe, and degrade cleanly in narrow or non-TUI modes
- [ ] #6 HostedPiRuntimeActor consumes reset/replay/revision-fenced owner-private identity/lifecycle/activity projection and updates only exactly owned pane/window title, border, or status after full ownership validation
- [ ] #7 Topic, reducer, overlay, renderer, or tmux failure degrades only disposable visibility and cannot change AgentActor authority, lifecycle, routing, task state, role, access mode, or activity
- [ ] #8 Automated and fresh-process live E2E prove realtime updates, unknown/set/clear/stale/reconnect behavior, expanded interaction, lifecycle independence, exact tmux ownership, no polling, and full terminal Pi restart deployment
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Operator priority: current footer is missing trustworthy realtime/live updates. Ship the compact live status path first, then add a nice expandable interactive overlay when Pi APIs permit it without replacing the global footer or introducing authority. `/reload` is not a deployment gate; live proof uses a fresh terminal Pi process.

WorkflowActor references are superseded. Activity authority belongs to normal retained AgentActors (including a crew supervisor when configured); the client remains projection-only.
<!-- SECTION:NOTES:END -->
