---
id: TASK-5
title: Implement XState client projections slice
status: In Progress
assignee:
  - '@pi'
created_date: '2026-08-31 21:41'
updated_date: '2026-09-02 02:17'
labels: []
dependencies:
  - TASK-4
priority: high
type: feature
ordinal: 5000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement xstate 5.20.2 client actors as the actor-client projection data layer and derive responsive, theme-aware Pi TUI status and conversation widgets from bounded snapshots.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 actor-client pins xstate exactly to 5.20.2 in package and lockfile
- [x] #2 Typed XState actors cover connection, roster/cursor, pending interactions, conversation cards, replay dedupe, and bounded render snapshots
- [x] #3 Rich Pi TUI widgets render Tell, Ask, completion, failure, busy, and status states responsively from projection snapshots
- [x] #4 Daemon actors remain authoritative and status remains topic-driven with no actor_list polling
- [x] #5 Deterministic unit and integration tests cover replay, reconnect, stale frames, resize, redaction, and model-visible completion behavior
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add exact xstate dependency and extract typed projection actors/selectors from index.ts.
2. Adapt websocket, regular-delivery, and Pi lifecycle events into machine events without moving durable authority client-side.
3. Build reusable Pi TUI status and conversation widgets derived from bounded snapshots.
4. Migrate actor-client wiring incrementally while preserving existing tool/model contracts.
5. Add deterministic tests and run repository gates.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
TASK-4 synthesis is complete and reviewed. UI Projection Implementer is the sole writer in /home/shyylol/dev/lazyvim-ui-projections; implementation must begin by rebasing work/ui-projections onto shared main and follow the frozen TASK-4 contract.

Implemented actor-client projection modules with an XState 5.20.2 root machine, exact package/lock integrity pin, lifecycle verification, responsive bounded projection widgets, canonical completion dedupe/collision tests, and adapter-confirmed completion presentation guard. Focused actor-client tests pass; tmux/dry-run blockers are environment-missing tmux/stylua as documented in final report.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented actor-client XState 5.20.2 projection slice with exact dependency/integrity verification, topic-backed pure roster/pending/conversation/layout projections, responsive widgets, migration adapters, and deterministic actor-client tests. Verified with actor-client npm test, capabilities test, diff check, tmux suite except host-missing tmux integration cases, and services gates after rerun.
<!-- SECTION:FINAL_SUMMARY:END -->
