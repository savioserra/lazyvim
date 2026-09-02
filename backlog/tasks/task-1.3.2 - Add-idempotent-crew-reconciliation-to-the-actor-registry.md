---
id: TASK-1.3.2
title: Add idempotent crew reconciliation to the actor registry
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 04:46'
updated_date: '2026-09-02 05:24'
labels: []
dependencies:
  - TASK-1.3.1
references:
  - services/subagents/internal/actors/agent_registry.go
  - services/subagents/internal/service/service.go
  - services/subagents/api/subagents/v1/subagents.proto
parent_task_id: TASK-1.3
priority: high
type: feature
ordinal: 25000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add an authenticated daemon operation that reconciles a validated crew manifest through the internal actor registry. Stable logical AgentActors and their hosted runtimes are retained and reused; retries create only missing entries and never create parallel writers.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The daemon accepts a canonical project/manifest identity and normalized crew entries through an authenticated protocol and delegates creation/reuse to the internal registry rather than shelling out or invoking public admin tools
- [ ] #2 Sequential and concurrent identical reconciliations return one authoritative per-agent result and create at most one AgentActor/runtime for each stable ID
- [ ] #3 Retry after partial failure creates only missing entries and reports created, existing, and conflict outcomes without stopping or replacing retained actors
- [ ] #4 Conflicting stable identity or incompatible manifest revisions fail closed; prompts, credentials, host data, runtime IDs, fences, principals, and process/tmux details are redacted from public results
- [ ] #5 Durable restart, remote placement, reconnect, and race tests prove idempotency and one-writer enforcement without WorkflowActor participation
- [ ] #6 Reconciliation treats the optional supervisor as one ordinary retained AgentActor with crew-scoped capabilities and the same idempotent create/existing/conflict result contract as participants
<!-- AC:END -->
