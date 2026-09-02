---
id: TASK-1.2
title: Publish dynamic actor activity projections to clients and runtimes
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 02:56'
updated_date: '2026-09-02 04:32'
labels: []
dependencies:
  - TASK-1.1
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
Publish authoritative, revision-fenced dynamic activity metadata from AgentActor or WorkflowActor and project it through topic-backed roster/status/UI surfaces. Phase keys and human labels are supplied by the owning workflow/domain at runtime; reviewing, testing, correcting, or any other domain activity is not a central enum and is never inferred from role. Process, tmux, heartbeat, tool output, and elapsed time must never infer activity. Because each hosted Pi runtime actor is bound to its owning AgentActor, it subscribes to the owner's bounded activity/identity topic projection and updates only its exactly owned tmux UI from authenticated facts.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 AgentActor or WorkflowActor publishes a typed activity envelope with opaque bounded phase key, optional human label/details, authoritative source, revision, and ownership semantics; the protocol does not enumerate domain phase values
- [ ] #2 Role and activity are independent dynamic metadata: role changes do not synthesize activity, identical roles may publish different activities, and workflows/packages may introduce new phase keys without daemon/client code changes
- [ ] #3 Actor-client consumes activity only through authenticated topic push, rejects stale revisions, and renders sanitized dynamic labels without polling actor_list or exposing private runtime fields
- [ ] #4 Tests and live E2E prove workflow-defined phase values, unknown/new values, role changes, stale updates, clearing activity, and failure/degraded lifecycle remain truthful and bounded
- [ ] #5 The hosted Pi runtime actor subscribes to its owning AgentActor/WorkflowActor topic projection and receives reset/replay/revision-fenced identity, lifecycle, and dynamic activity updates without polling or terminal scraping
- [ ] #6 The runtime updates the exactly owned tmux pane/window UI from topic facts only after validating the full ownership tuple; adopted or foreign panes are never mutated
- [ ] #7 Topic/subscriber, renderer, or tmux UI failure degrades only the disposable runtime view and cannot change AgentActor/WorkflowActor authority, lifecycle, routing, task state, role, or activity
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
User requirement: treat the tmux-hosted Pi runtime as an actor-bound subscriber of its owning AgentActor topics so pane UI follows the same authoritative identity/phase projection as actor-client status. This is part of TASK-1.2, not a separate liveness-derived observer authority.

User correction: productive phase values are domain/workflow metadata, not a hardcoded enum and not derived from dynamic actor roles. Reviewing/testing/correcting are examples a workflow may publish, never daemon-wide constants.

Corrected UX report received directly at sequence 58. Frozen human contract: render lifecycle/availability, dynamic activity, role, access mode, and visibility health as independent facts. Activity envelope supports set/clear/reset, authoritative owner, monotonic revision, opaque bounded key, optional label/detail, and actor-vs-workflow ownership. Unknown keys render via sanitized label or naturalized key; absent/cleared activity removes only that segment and never invents idle. Status is one-line bounded with +N; roster/pane layouts prioritize display name, lifecycle, then activity and collapse safely. Role/activity never imply each other. Visibility failure cannot alter activity. Required E2E covers unknown/unsafe values, clear, role/activity independence, same-role differences, lifecycle separation, stale fencing, reconnect replay, owner-bound runtime subscription, exact tmux ownership, narrow bounds, and no polling/scraping/injection.
<!-- SECTION:NOTES:END -->
