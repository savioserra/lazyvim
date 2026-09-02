---
id: TASK-22.1
title: Freeze AgentActor thread and introspection architecture
status: In Progress
assignee:
  - '@pi'
created_date: '2026-09-02 06:10'
updated_date: '2026-09-02 06:13'
labels: []
dependencies: []
parent_task_id: TASK-22
priority: high
type: docs
ordinal: 36000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Record the implementation-ready authority, identity, durability, scheduling, introspection, privacy, migration, and failure contract for durable AgentActor threads before runtime code changes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The ADR defines a target-authoritative thread_id distinct from request, dedupe, chain, task, delivery, and completion identities
- [ ] #2 The ADR defines durable-before-effect thread transitions, one-active-thread scheduling, fairness, restart recovery, and exactly-once completion routing
- [ ] #3 The ADR defines isolated structured introspection after agent_settled, exact model configuration, validation, bounds, backoff, and fail-closed completion gating
- [ ] #4 Independent actor-model review approves the contract with no unresolved high-severity findings
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Convert Ask 89 into a concise ADR, challenge identity/completion/privacy assumptions, review independently, then freeze the contract.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Added ADR 0006 draft as implementation-authoritative durable thread/introspection contract and updated docs/subagents plus roadmap cross-references. No runtime code implemented.
<!-- SECTION:NOTES:END -->
