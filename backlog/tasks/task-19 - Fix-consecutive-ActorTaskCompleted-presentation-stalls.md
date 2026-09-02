---
id: TASK-19
title: Fix terminal actor delivery stalls and stale ACK fences
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 03:03'
updated_date: '2026-09-02 03:20'
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

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Additional live evidence: sequence 34 appeared only after the user sent a later turn, rather than waking/presenting when the durable completion first committed. Its payload was only a report receipt, but the delayed wake behavior confirms the consecutive-completion presentation stall remains observable.

Live proactive-Ask evidence: UI QA retained four outbox messages to the project-manager alias (one sent with high retry count, three pending credit); UI UX retained three. Daemon logs show terminal delivery ACK rejection under a rotated fence and repeated credit_reservation_missing redrive. The visible panel wording was optimistic local tool state, not authoritative delivery.
<!-- SECTION:NOTES:END -->
