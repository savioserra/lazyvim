---
id: TASK-22.1
title: Freeze AgentActor thread and introspection architecture
status: Done
assignee:
  - '@pi'
created_date: '2026-09-02 06:10'
updated_date: '2026-09-02 06:52'
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
- [x] #1 The ADR defines a target-authoritative thread_id distinct from request, dedupe, chain, task, delivery, and completion identities
- [x] #2 The ADR defines durable-before-effect thread transitions, one-active-thread scheduling, fairness, restart recovery, and exactly-once completion routing
- [x] #3 The ADR defines isolated structured introspection after agent_settled, exact model configuration, validation, bounds, backoff, and fail-closed completion gating
- [x] #4 Independent actor-model review approves the contract with no unresolved high-severity findings
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Convert Ask 89 into a concise ADR, challenge identity/completion/privacy assumptions, review independently, then freeze the contract.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Added ADR 0006 draft as implementation-authoritative durable thread/introspection contract and updated docs/subagents plus roadmap cross-references. No runtime code implemented.

Notification-fix deployment interrupted ADR correction only after architect commit was safely present in its retained git worktree. Actor was explicitly restarted at operator request and recreated against the same worktree; correction commit remains available for integration.

Architect correction commit d097e7d resolved review 92. PM integration also repaired sanitizer-corrupted `--no-session`, required unambiguous provider/model syntax, replaced WorkflowActor wording with crew/workflow state plus typed access mode, and specified bounded RPC JSONL framing before strict assistant JSON parsing.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Accepted ADR 0006 as the implementation authority for target-owned durable AgentActor threads, one-active fair scheduling, daemon-issued settlement identity, isolated exact-model Pi RPC introspection, strict fail-closed parsing, atomic v2-to-v3 migration, full worker-result completion routing, bounded recovery, privacy, and crash behavior. Independent final Ask 98 approved the corrected origin blob with no high or critical findings.
<!-- SECTION:FINAL_SUMMARY:END -->
