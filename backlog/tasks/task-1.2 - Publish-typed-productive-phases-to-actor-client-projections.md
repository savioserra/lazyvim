---
id: TASK-1.2
title: Publish typed productive phases to actor client projections
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 02:56'
updated_date: '2026-09-02 02:56'
labels: []
dependencies:
  - TASK-1.1
references:
  - docs/architecture/subagents/ACTOR-UX-DESIGN-SYSTEM.md
parent_task_id: TASK-1
priority: high
type: feature
ordinal: 20000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Publish authoritative productive phase from AgentActor or WorkflowActor and project it through topic-backed roster/status/UI surfaces. Valid phases include idle, working, waiting, reviewing, testing, correcting, failed, and degraded. Process, tmux, heartbeat, tool output, and elapsed time must never be used to infer productive work.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 AgentActor or WorkflowActor publishes a typed, revision-fenced productive phase with explicit ownership and lifecycle semantics
- [ ] #2 Actor-client consumes phase only through authenticated topic push and rejects stale phase revisions without polling actor_list
- [ ] #3 Status and observer labels render sanitized phase and dynamic identity while omitting private transport/runtime/tmux details
- [ ] #4 Tests and live E2E prove truthful phase transitions through worker, reviewer, QA, correction, waiting, and failure states
<!-- AC:END -->
