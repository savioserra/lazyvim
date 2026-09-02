---
id: TASK-3
title: 'Architecture research: roster/status projections and topic contract'
status: In Progress
assignee:
  - '@pi'
created_date: '2026-08-31 21:41'
updated_date: '2026-09-02 01:06'
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
- [ ] #1 Specifies typed XState v5 machines/actors and deterministic event-to-snapshot boundaries
- [ ] #2 Specifies epoch/sequence fencing, reconnect cursors, replay dedupe, and stale-event rejection
- [ ] #3 Keeps transport effects and Pi rendering adapters outside pure projection logic
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Audit current reducers, websocket push events, reconnect lifecycle, delivery coordinator, and tests.
2. Define machine topology, typed events/context, invariants, effect boundaries, selectors, and snapshot contracts.
3. Produce a migration plan that pins xstate 5.20.2 and preserves protocol authority and exact-once UI behavior.
<!-- SECTION:PLAN:END -->
