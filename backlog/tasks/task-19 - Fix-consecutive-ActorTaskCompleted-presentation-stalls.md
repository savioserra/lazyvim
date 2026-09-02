---
id: TASK-19
title: Fix terminal actor delivery stalls and stale ACK fences
status: In Progress
assignee:
  - '@pi'
created_date: '2026-09-02 03:03'
updated_date: '2026-09-02 03:31'
labels: []
dependencies: []
references:
  - >-
    docs/architecture/subagents/0005-daemon-connected-bridge-and-frontend-projections.md
  - home/dot_pi/private_agent/extensions/actor-client/index.ts
  - services/subagents/internal/service/actor_reply_broker.go
priority: high
type: bug
ordinal: 22000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Terminal actor delivery remains unreliable in two related live paths. First, consecutive ActorTaskCompleted results can commit durably but wait for a later user turn before presentation. Second, hosted agents use the source display label `Project Manager` for proactive Ask/Tell; the panel shows optimistic `Asking Project Manager…`, but durable outboxes retain a `project-manager` alias, terminal regular deliveries reject ACK with a stale attachment fence, and later messages remain pending credit. Diagnose canonical reply-to-source resolution, terminal attachment/fence renewal, regular delivery ACK identity, reply broker push, presentation wake, and persisted dedupe/cursor state. Durable completion or optimistic tool text is not successful human delivery.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Three or more consecutive fresh ActorTaskCompleted results automatically reach and wake the requesting terminal without another user turn, pane inspection, or durable-state polling
- [ ] #2 A hosted actor can Ask and Tell the authoritative source terminal using a canonical reply capability or resolved identity; display-name aliases never create an unroutable pseudo-agent
- [ ] #3 Terminal reconnect/reattach renews the regular-delivery ACK fence consistently, replays committed work exactly once, and cannot loop on fence rejection or credit churn
- [ ] #4 Optimistic Asking/Sending UI transitions to authoritative admitted, busy, failed, or completed state and never implies delivery before admission
- [ ] #5 Service and actor-client regressions reproduce consecutive-completion delay plus hosted-agent-to-source Ask under fence rotation, and live E2E proves both without polling or pane inspection
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reproduce canonical client identity alias leakage, stale regular ACK fence, and missed consecutive wake in focused service/client tests.
2. Preserve canonical client stable IDs while keeping friendly display metadata; resolve or reject presentation aliases before any durable outbox write and define server-issued reply-to-source routing.
3. Make regular delivery ACK obtain the current self attachment fence and retry exactly once after fenced reattach without reinjection or duplicate presentation.
4. Wake canonical terminal sessions for every committed completion and add bounded legacy alias repair/quarantine that preserves dedupe and never fabricates success.
5. Run service/client/security/reconnect regressions and a live multi-message hosted-agent-to-source E2E before finalization.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Additional live evidence: sequence 34 appeared only after the user sent a later turn, rather than waking/presenting when the durable completion first committed. Its payload was only a report receipt, but the delayed wake behavior confirms the consecutive-completion presentation stall remains observable.

Live proactive-Ask evidence: UI QA retained four outbox messages to the project-manager alias (one sent with high retry count, three pending credit); UI UX retained three. Daemon logs show terminal delivery ACK rejection under a rotated fence and repeated credit_reservation_missing redrive. The visible panel wording was optimistic local tool state, not authoritative delivery.

Architecture diagnosis sequence 39 identified three interacting bugs: communicationPeer rewrites canonical client:* stable identity to presentation alias project-manager; regular delivery retains stale ACK fence across reattach; broker wake depends on serialized source principal matching the active terminal. Frozen fix direction: preserve canonical stable IDs, resolve/reject aliases before durable outbox, add canonical reply-to-source capability, refresh/retry ACK once with unchanged delivery identity, wake canonical sessions, and quarantine ambiguous legacy alias items.

TASK-19 implementation is assigned to the retained UI Projection Implementer after completion of TASK-1.1 correction writing. It may change service and actor-client code but remains the sole writer in its worktree; independent review/QA remain read-only.

Operator deployment decision: after reviewed code is applied, perform an explicit whole-crew recovery teardown. Preserve the active PM until the handoff point; retire each exactly owned hosted actor/runtime, remove observer clients/window, stop the daemon, clear only the configured actor durable state after exact ownership is gone, restart the daemon, reload/reconnect PM, recreate the five logical UI crew actors with fresh Pi runtimes in their clean isolated worktrees, and rebuild the labeled 3x2  tmux window. This explicit operator request authorizes stop/shutdown only for this deployment reset; ordinary phase transitions still retain actors.
<!-- SECTION:NOTES:END -->
