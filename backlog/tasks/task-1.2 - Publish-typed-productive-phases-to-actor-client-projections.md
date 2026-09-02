---
id: TASK-1.2
title: Publish typed productive phases to actor client projections
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 02:56'
updated_date: '2026-09-02 04:24'
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
Publish authoritative productive phase from AgentActor or WorkflowActor and project it through topic-backed roster/status/UI surfaces. Valid phases include idle, working, waiting, reviewing, testing, correcting, failed, and degraded. Process, tmux, heartbeat, tool output, and elapsed time must never be used to infer productive work. Because each hosted Pi runtime actor is bound to its owning AgentActor, it also subscribes to the owner's bounded phase/identity topic projection and updates only its exactly owned tmux UI from those authenticated facts.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 AgentActor or WorkflowActor publishes a typed, revision-fenced productive phase with explicit ownership and lifecycle semantics
- [ ] #2 Actor-client consumes phase only through authenticated topic push and rejects stale phase revisions without polling actor_list
- [ ] #3 Status and observer labels render sanitized phase and dynamic identity while omitting private transport/runtime/tmux details
- [ ] #4 Tests and live E2E prove truthful phase transitions through worker, reviewer, QA, correction, waiting, and failure states
- [ ] #5 The hosted Pi runtime actor subscribes to its owning AgentActor/WorkflowActor topic projection and receives reset/replay/revision-fenced identity, lifecycle, and productive-phase updates without polling or terminal scraping
- [ ] #6 The runtime updates the exactly owned tmux pane/window UI from topic facts only after validating the full ownership tuple; adopted or foreign panes are never mutated
- [ ] #7 Topic/subscriber, renderer, or tmux UI failure degrades only the disposable runtime view and cannot change AgentActor/WorkflowActor authority, lifecycle, routing, or task state
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
User requirement: treat the tmux-hosted Pi runtime as an actor-bound subscriber of its owning AgentActor topics so pane UI follows the same authoritative identity/phase projection as actor-client status. This is part of TASK-1.2, not a separate liveness-derived observer authority.
<!-- SECTION:NOTES:END -->
