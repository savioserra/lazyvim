---
id: TASK-4
title: Team discussion and design synthesis
status: Done
assignee:
  - '@pi'
created_date: '2026-08-31 21:41'
updated_date: '2026-09-02 02:05'
labels: []
dependencies:
  - TASK-2
  - TASK-3
priority: high
type: task
ordinal: 4000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Synthesize UX and architecture research into one reviewed implementation contract for the actor-client XState data layer and rich Pi TUI widgets.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Resolves researcher disagreements against ADR 0005 and the actor UX design system
- [x] #2 Produces a file-level implementation contract, event catalog, selectors, widgets, and test matrix
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Cross-review TASK-2 and TASK-3 findings.
2. Resolve conflicts around authority, replay, status truthfulness, and transcript rendering.
3. Freeze a bounded implementation contract for TASK-5.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
TASK-2 and TASK-3 research are complete. UI Projection Reviewer was assigned an independent architecture critique through request 30fe3e76 at source sequence 26; synthesis will resolve its findings before TASK-5 starts.

UI Projection Reviewer completed read-only critique through ActorTaskCompleted at source sequence 26. All P0 corrections are accepted. Frozen synthesis: (1) one root XState v5 actor owns session generation, connection/auth/subscription lifecycle, replay cursors, and context slices; a completion is one root transaction that clears pending, records canonical completion-key/digest, emits one presentation intent, and advances cursor only after adapter confirmation. Pure slice reducers/selectors may be separate modules, but independently invoked sibling machines may not race cross-slice updates. (2) roster requires reset-first higher epochs, rejects <= duplicates, detects same-epoch gaps, and degrades/resubscribes instead of rendering incomplete truth. (3) completionKey is primary; request ID exists only in a collision-checked migration adapter. (4) Pi send/persistence is an effect intent; presented/seen commits only after adapter success. (5) actor-client pins/verifies its own xstate 5.20.2 key and integrity without changing tmux-subagents xstate 5.32.6. (6) ActorMessageResponse means admission/backpressure only; ActorTaskCompleted is completion authority; ActorMessageReplyFrame is isolated migration input. (7) reducers/selectors/layout are immutable and pure; redaction occurs at ingress into sanitized DTOs. (8) connection states are disconnected, connecting, authenticating, subscribingRoster, connected, reconnecting, degraded, closing. File contract: projections/{types,machine,events,ports,sanitize,dedupe,selectors,roster,pending,conversation,layout}.ts plus widgets/{status,conversation-card}.ts; index.ts executes transport/Pi/filesystem/timer effects only; regular-delivery.ts and reply-frame code are adapters. Event catalog includes SESSION.*, TRANSPORT.*, ROSTER.FRAME/RESET/GAP, TASK.ADMITTED/BACKPRESSURED/COMPLETED, PRESENTATION.SUCCEEDED/FAILED, DELIVERY.INCOMING.*, RESTORE.*, VIEW.WIDTH/THEME. Render snapshot is bounded and the only widget input. Tests must cover duplicate/gap/reset fencing, atomic completion transaction, canonical collision, sendMessage failure replay, hidden pending restore, resize idempotence, ingress redaction, exact pins, admission-vs-completion authority, and narrow/wide width bounds.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Synthesized the UX and architecture reports with independent review into one frozen implementation contract: a transactional root XState actor, pure projection slices/selectors, canonical completion-key replay, reset/gap-fenced topic status, adapter-confirmed presentation effects, ingress redaction, responsive bounded widgets, actor-client-specific dependency pins, and a deterministic test matrix.
<!-- SECTION:FINAL_SUMMARY:END -->
