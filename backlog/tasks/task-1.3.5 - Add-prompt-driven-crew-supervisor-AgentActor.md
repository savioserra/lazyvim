---
id: TASK-1.3.5
title: Add prompt-driven crew supervisor AgentActor
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 05:25'
labels: []
dependencies:
  - TASK-1.2
  - TASK-1.3.3
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
Support an optional `[crew.supervisor]` manifest section that bootstraps one retained AgentActor with a specialized default system prompt. The supervisor observes authenticated projections for only its declared crew and takes coordination actions through ordinary typed actor protocols. It is not a WorkflowActor, transport-derived actor class, daemon phase machine, or tmux controller.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A valid `[crew.supervisor]` reconciles to exactly one stable retained AgentActor/runtime and repeated, concurrent, reconnect, and restart spawn paths reuse it idempotently
- [ ] #2 Supervisor behavior is configured by stable identity, dynamic metadata, bounded prompt, and explicit crew-scoped capabilities; no role string or transport identity synthesizes supervisor authority
- [ ] #3 The supervisor receives reset/replay-safe authenticated topic projections for declared participant identity, lifecycle, activity, access mode, task admission/completion, and visibility without `actor_list` polling, terminal scraping, or liveness/activity inference
- [ ] #4 Based on its loaded prompt, the supervisor can assign work, request architecture/UI/review/QA input, route corrections, and report completion using ActorTask/ActorTaskCompleted and Tell/Ask to stable AgentActor identities
- [ ] #5 Coordination preserves one active writer per cwd/worktree, retained participants, source-routed completion, bounded backpressure, and durable-before-effect ordering
- [ ] #6 The supervisor cannot use ordinary coordination to stop, abort, shutdown, respawn, inject into, scrape, or mutate foreign/user actors or panes; management controls remain explicit operator actions
- [ ] #7 Projection gaps, model/runtime failure, stale revisions, authorization failure, or unavailable participants degrade visibly and recover by replay/retry without inventing activity, duplicating actions, or silently escalating authority
- [ ] #8 Unit, race, restart, reconnect, redaction, capability, and live E2E tests prove prompt loading, scoped observation, deterministic idempotency, typed coordination, one-writer enforcement, and no WorkflowActor dependency
<!-- AC:END -->
