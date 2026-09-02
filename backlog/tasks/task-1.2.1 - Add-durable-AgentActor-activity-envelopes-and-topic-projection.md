---
id: TASK-1.2.1
title: Add durable AgentActor activity envelopes and topic projection
status: In Progress
assignee:
  - '@pi'
created_date: '2026-09-02 05:40'
updated_date: '2026-09-02 13:03'
labels: []
dependencies: []
references:
  - services/subagents/api/subagents/v1/subagents.proto
  - services/subagents/internal/actors/agent.go
  - services/subagents/internal/actors/agent_registry.go
parent_task_id: TASK-1.2
priority: high
type: feature
ordinal: 30000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add the additive protocol, durable AgentActor state, authority validation, and bounded topic projection for opaque dynamic activity set/clear metadata. This slice establishes authoritative facts and replay semantics without UI effects.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Protocol and application types represent opaque bounded key, optional label/details, owner/source identity, epoch/revision, timestamp, and durable clear marker without a domain enum
- [ ] #2 Only the owning AgentActor or explicitly authorized crew supervisor assignment can set/clear activity, and persistence commits before publication or response
- [ ] #3 Same revision/different digest fails closed, stale revisions are rejected, role/lifecycle updates preserve activity, and clear fences older set replay without inventing idle
- [ ] #4 Registry/topic snapshots and cursor replay expose only sanitized public fields while owner-private topics retain only the additional facts required by the bound runtime
- [ ] #5 Race, persistence, restart, reset, gap, collision, unknown-key, redaction, and role/lifecycle-independence tests pass
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Read-only current-code architecture audit assigned before implementation; no writer starts until protocol/topic authority and migration seams are frozen.

Architecture Ask 84 returned from a stale worktree and old ADR/cutover scope, so it is not authoritative for current TASK-1.2.1. Superseded claims include missing XState/pin (current actor-client already pins xstate 5.20.2 and uses projection machines), fixed productive-phase/WorkflowActor authority (replaced by opaque runtime-defined activity), and HostedPiBridgeActor authority cutover as an activity prerequisite. Retain only contract-compatible evidence: activity must be explicit, opaque, durable-before-topic-push, owner-private, revision/epoch fenced, payload-free publicly, never inferred from role/lifecycle/tmux/process/heartbeat/output, and actor_list remains explicit inventory only rather than status refresh. The activity topic/envelope implementation remains outstanding.

Post-fix UI/UX contract confirms this slice must supply opaque durable activity plus owner-private sanitized thread aggregates through authenticated push/replay, with no polling or inference.
<!-- SECTION:NOTES:END -->
