---
id: TASK-3
title: 'Architecture research: roster/status projections and topic contract'
status: Done
assignee:
  - '@pi'
created_date: '2026-08-31 21:41'
updated_date: '2026-09-02 01:51'
labels: []
dependencies: []
priority: high
type: spike
ordinal: 3000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Define the XState v5 frontend data layer for disposable actor-client projections. Daemon actors remain authoritative; client actors own only connection, roster, cursor, pending interaction, conversation-card, and render-snapshot state.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Specifies typed XState v5 machines/actors and deterministic event-to-snapshot boundaries
- [x] #2 Specifies epoch/sequence fencing, reconnect cursors, replay dedupe, and stale-event rejection
- [x] #3 Keeps transport effects and Pi rendering adapters outside pure projection logic
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Audit current reducers, websocket push events, reconnect lifecycle, delivery coordinator, and tests.
2. Define machine topology, typed events/context, invariants, effect boundaries, selectors, and snapshot contracts.
3. Produce a migration plan that pins xstate 5.20.2 and preserves protocol authority and exact-once UI behavior.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Frontend Architecture Researcher report received automatically through ActorTaskCompleted at source sequence 24. Contract: pin xstate 5.20.2 and verify it in the subagents package; add projections/{types,app-machine,connection-machine,roster-machine,pending-machine,conversation-machine,render-snapshot-machine,dedupe,sanitize,selectors,ports}.ts; keep index.ts as protobuf/WebSocket/Pi effect adapter; machines own disposable connection, roster cursor, pending, conversation dedupe, and bounded render snapshots only. Daemon remains authoritative for lifecycle, delivery ACK retirement, routing, mutation sequence, runtime state, and productive status. Use typed effect intents/ports rather than WebSocket or Pi calls inside machines. Target first slices: pure sanitization/dedupe/selectors, roster machine, pending/conversation, render snapshot, integration wiring. Required tests cover bounded reconnect, shutdown without actor control, stale cursor rejection/reset, hidden pending markers, exactly-once completions, collision fail-closed, one incoming follow-up/card, resize without append, redaction, bounds, and exact package pin.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Specified typed XState v5 projection boundaries, pure event/snapshot contracts, epoch/sequence fencing, replay/collision behavior, effect ports, selectors, file layout, xstate 5.20.2 pin, migration order, and deterministic tests. Verified by the full Architecture Researcher ActorTaskCompleted report at source sequence 24.
<!-- SECTION:FINAL_SUMMARY:END -->
