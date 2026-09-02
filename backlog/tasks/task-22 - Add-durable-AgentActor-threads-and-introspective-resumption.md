---
id: TASK-22
title: Add durable AgentActor threads and introspective resumption
status: In Progress
assignee:
  - '@pi'
created_date: '2026-09-02 06:00'
labels: []
dependencies: []
references:
  - docs/architecture/subagents/0002-global-agent-and-hosted-pi-runtime.md
  - >-
    docs/architecture/subagents/0003-application-plane-routing-and-persistence.md
  - >-
    docs/architecture/subagents/0005-daemon-connected-bridge-and-frontend-projections.md
  - services/subagents/internal/actors/agent.go
  - home/dot_pi/private_agent/extensions/hosted-pi-bridge/index.ts
priority: high
type: feature
ordinal: 35000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Give every hosted AgentActor durable Slack-like task threads so a later mailbox item cannot erase or orphan earlier work. After each model turn the actor evaluates the active thread with a separately configured introspection model; incomplete work remains resumable and is automatically picked up again according to bounded mailbox scheduling, including after compaction, disconnect, or runtime restart.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Every admitted ActorTask is durably associated with exactly one stable thread identity and ordered thread messages before delivery; subsequent tasks cannot overwrite, complete, or retire another thread
- [ ] #2 The daemon persists bounded thread state and an explicit scheduler state for queued, active, waiting, blocked, completed, and failed work without inferring domain activity or role from thread state
- [ ] #3 After each hosted model turn settles, a bounded structured introspection step evaluates only the active thread and records completed, continue, waiting, or blocked before any completion, resumption, publication, or next-thread effect
- [ ] #4 When no mailbox item has higher scheduling priority, incomplete resumable work is automatically prompted from its durable thread checkpoint; queued work is scheduled fairly and one actor never runs two writing threads concurrently
- [ ] #5 The strict private config accepts an exact introspection model property, rejects invalid/unknown values, documents the setting, and passes it only to the isolated introspection routine rather than changing the hosted worker model
- [ ] #6 Compaction, actor/runtime restart, requester disconnect, duplicate task delivery, duplicate turn settlement, introspection failure/timeout, and daemon crash recover without losing or duplicating thread work or ActorTaskCompleted
- [ ] #7 Introspection and resume loops are bounded with explicit backoff/exhaustion behavior; malformed model output fails closed and cannot mark work complete
- [ ] #8 Thread status can feed owner-private projections using bounded payload-free metadata, while public roster/status surfaces expose no prompts, answers, checkpoints, model names, runtime IDs, or thread internals
- [ ] #9 Deterministic actor, persistence, bridge, configuration, restart, race, and fresh hosted-runtime E2E tests prove task A resumes after task B and completes without operator reminders, polling, or pane inspection
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Freeze the thread identity, persistence, scheduling, and structured introspection contracts with actor-model/Pi architecture review.
2. Add strict introspection-model configuration, durable schema migration, thread mailbox/scheduler state, and hosted bridge introspection/resume protocol.
3. Implement bounded recovery-safe scheduling and completion publication, then expose sanitized owner-private thread projection metadata.
4. Run independent review, race/restart tests, and a fresh hosted-runtime A→B→resume-A E2E.
<!-- SECTION:PLAN:END -->
