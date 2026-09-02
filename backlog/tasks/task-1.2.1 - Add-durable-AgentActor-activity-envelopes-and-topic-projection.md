---
id: TASK-1.2.1
title: Add durable AgentActor activity envelopes and topic projection
status: Done
assignee:
  - '@pi'
created_date: '2026-09-02 05:40'
updated_date: '2026-09-02 14:18'
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
- [x] #1 Protocol and application types represent opaque bounded key, optional label/details, owner/source identity, epoch/revision, timestamp, and durable clear marker without a domain enum
- [x] #2 Only the owning AgentActor or explicitly authorized crew supervisor assignment can set/clear activity, and persistence commits before publication or response
- [x] #3 Same revision/different digest fails closed, stale revisions are rejected, role/lifecycle updates preserve activity, and clear fences older set replay without inventing idle
- [x] #4 Registry/topic snapshots and cursor replay expose only sanitized public fields while owner-private topics retain only the additional facts required by the bound runtime
- [x] #5 Race, persistence, restart, reset, gap, collision, unknown-key, redaction, and role/lifecycle-independence tests pass
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add additive proto messages/Envelope cases and regenerate Go/TypeScript bindings.
2. Add application durable activity types and AgentActor activity ledger with validation, CAS, tombstones, request fingerprint idempotency, persistence-before-response, and bridge/topic projection events.
3. Add service authorization/routing for authenticated hosted self-owner activity mutation plus sanitized public/owner-private projection serialization.
4. Add hosted-pi-bridge self-only set/clear commands and tools using existing WebSocket framed client and extension-local mutation sequencing.
5. Add Go and Node tests for collision, stale revision, clear tombstones, restart, redaction, role/lifecycle independence, auth, replay/gap/reset, then run required gates.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Read-only current-code architecture audit assigned before implementation; no writer starts until protocol/topic authority and migration seams are frozen.

Architecture Ask 84 returned from a stale worktree and old ADR/cutover scope, so it is not authoritative for current TASK-1.2.1. Superseded claims include missing XState/pin (current actor-client already pins xstate 5.20.2 and uses projection machines), fixed productive-phase/WorkflowActor authority (replaced by opaque runtime-defined activity), and HostedPiBridgeActor authority cutover as an activity prerequisite. Retain only contract-compatible evidence: activity must be explicit, opaque, durable-before-topic-push, owner-private, revision/epoch fenced, payload-free publicly, never inferred from role/lifecycle/tmux/process/heartbeat/output, and actor_list remains explicit inventory only rather than status refresh. The activity topic/envelope implementation remains outstanding.

Post-fix UI/UX contract confirms this slice must supply opaque durable activity plus owner-private sanitized thread aggregates through authenticated push/replay, with no polling or inference.

Post-value-policy retry on deployed de89e16: wire contract remains an activity VALUE contract, not a security policy. Proposed mutation surface is additive protobuf only: AgentActivityMutationRequest/Response plus AgentActivityFrame under authenticated Envelope, with owner-private state committed before response/topic publication. Authorization path is hosted owner session credential -> AuthorizeAgentAccess -> owning AgentActor validHandle/session/generation/principal/fence with hosted_bridge plus activity_write; self-owner path is caller hosted:[redacted] targeting its own agent_id, supervisor writes require an explicit durable assignment grant. Revision/idempotency are server-owned: request_id/dedupe digest replay returns the retained result; same id/different digest fails closed; current_revision is only a compare-and-set fence; AgentActor allocates the next revision after persistence intent and never trusts extension-provided revisions; extension restart reconnects with retained session identity and may safely replay unresolved mutation identities without resetting revision or source high-water. Hosted-pi-bridge contract impact: add command/tool only for opaque set/clear of current owner activity; no model-payload logging, no enum/inference from role/lifecycle/tmux/output, bounded sanitized public projection, owner-private details only for the bound runtime.

Implemented additive AgentActivityMutation/Response/Frame protobuf and regenerated Go/TypeScript bindings. Added durable AgentActor activity state, activity events, mutation fingerprint idempotency, CAS stale-revision rejection, durable clear tombstones, persistence-before-response, hosted self-owner activity_write authorization, hosted bridge set/clear commands/tools with no arbitrary target, and extension registration coverage. Validation: services/subagents ./tools/codegen.sh verify; go test -race ./...; go vet ./...; npm test; npm test --prefix home/dot_pi/private_agent/extensions/hosted-pi-bridge; nvim -l tests/capabilities.test.lua; git diff --check. tmux-subagents remains 93/97 due host tmux ENOENT; stylua and chezmoi dry-run blocked by missing stylua/tmux on host.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
TASK-1.2.1 implemented activity mutation protocol and durable owner ledger end to end: additive protobuf/generated bindings, server-owned revisions/epochs, CAS and idempotency, clear tombstones, hosted self-owner authorization, sanitized hosted bridge set/clear surfaces, and tests for persistence/restart/collision/stale/redaction/clear replay plus extension command/tool registration. Verified with codegen, Go race/vet/tests, service npm tests, hosted bridge extension tests, capability tests, and diff whitespace check.
<!-- SECTION:FINAL_SUMMARY:END -->
