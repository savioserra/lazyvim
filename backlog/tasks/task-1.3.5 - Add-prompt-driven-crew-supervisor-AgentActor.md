---
id: TASK-1.3.5
title: Add prompt-driven crew supervisor AgentActor
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 05:25'
updated_date: '2026-09-02 06:01'
labels: []
dependencies:
  - TASK-1.2
  - TASK-1.3.3
  - TASK-16
  - TASK-22
references:
  - .crew.toml
  - services/subagents/internal/actors/agent.go
  - services/subagents/internal/actors/agent_registry.go
  - home/dot_pi/private_agent/extensions/hosted-pi-bridge/index.ts
  - docs/architecture/subagents/ROADMAP.md
parent_task_id: TASK-1.3
priority: high
type: feature
ordinal: 28000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Support an optional `[crew.supervisor]` manifest section that bootstraps one retained background AgentActor with its own independently supervised hosted Pi runtime and durable Pi session. It is never the interactive terminal Pi session that discovered or spawned the crew. The supervisor continues parallel coordination when requester terminals disconnect and communicates with them only as peer actors through normal typed protocols. It is not a WorkflowActor, transport-derived actor class, daemon phase machine, or tmux controller.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A valid `[crew.supervisor]` reconciles to exactly one stable retained background AgentActor/runtime and repeated, concurrent, reconnect, and restart spawn paths reuse it idempotently
- [ ] #2 The supervisor owns a distinct stable actor identity, credentials, hosted runtime, and durable Pi session; it never aliases, adopts, blocks, or executes inside the interactive `client:*` terminal Pi session
- [ ] #3 Starting Pi or running `/crew spawn` only requests reconciliation; the initiating terminal remains an independent peer and may disconnect without stopping, passivating, or cancelling the background supervisor
- [ ] #4 Supervisor behavior is configured by stable identity, dynamic metadata, bounded prompt, and explicit crew-scoped capabilities; no role string, terminal principal, or transport identity synthesizes supervisor authority
- [ ] #5 The supervisor receives reset/replay-safe authenticated topic projections for declared participant identity, lifecycle, activity, access mode, task admission/completion, and visibility without `actor_list` polling, terminal scraping, or liveness/activity inference
- [ ] #6 Based on its loaded prompt, the supervisor runs in parallel and can assign work, request architecture/UI/review/QA input, route corrections, and report completion using ActorTask/ActorTaskCompleted and Tell/Ask to stable peer identities
- [ ] #7 Coordination preserves one active writer per cwd/worktree, retained participants, source-routed completion, bounded backpressure, and durable-before-effect ordering
- [ ] #8 The supervisor cannot use ordinary coordination to stop, abort, shutdown, respawn, inject into, scrape, or mutate foreign/user actors or panes; management controls remain explicit operator actions
- [ ] #9 Projection gaps, model/runtime failure, stale revisions, authorization failure, unavailable participants, or requester disconnect degrade visibly and recover by replay/retry without inventing activity, duplicating actions, or escalating authority
- [ ] #10 Unit, race, runtime-reincarnation, terminal-disconnect, restart, reconnect, redaction, capability, and live E2E tests prove independent background execution, prompt loading, scoped observation, deterministic idempotency, typed coordination, and no WorkflowActor dependency
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Clarification from operator: the supervisor is not the interactive Pi terminal session. It is an independent hosted background AgentActor/Pi runtime that works in parallel and outlives terminal attachment/disconnect.

Durable prompt-driven supervision depends on TASK-22 threads so later assignments cannot erase incomplete coordination and the supervisor can introspect/resume work after its mailbox drains.
<!-- SECTION:NOTES:END -->
