---
id: TASK-2
title: Research actor UX and XState client projections
status: Done
assignee:
  - '@pi'
created_date: '2026-08-31 21:41'
updated_date: '2026-09-02 01:51'
labels: []
dependencies: []
priority: high
type: spike
ordinal: 2000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Research the human UX for owned actor conversations, topic-backed status, reconnect/replay behavior, and responsive Pi TUI rendering. Produce implementation-ready user journeys and bounded/redacted presentation rules; do not create a second source of durable truth.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Defines compact Tell, Ask, completion, failure, busy, and replay-deduped conversation-card states
- [x] #2 Defines responsive narrow and wide layouts using Pi theme tokens without fixed transcript widgets
- [x] #3 Defines truthful topic-backed status semantics without polling actor_list or inferring productivity from liveness
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Audit the current actor-client status line, communication cards, Pi TUI primitives, and ADR constraints.
2. Specify user journeys, information hierarchy, state transitions, narrow/wide behavior, accessibility, and redaction.
3. Return an implementation matrix and critique the proposed XState projection boundaries.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
UI UX Researcher returned the complete implementation-ready brief through ActorTaskCompleted. It defines explicit incoming/outgoing Tell, Ask pending/completion, failure, busy/backpressure, replay collision, and user-decision states; canonical completion-key dedupe and terminal-wins restore order; topic-only roster/status truthfulness; responsive >=80 and <80/<50 Pi TUI layouts; theme/accessibility semantics; width, payload, entry, and redaction bounds; file-level projection/UI changes; and TASK-5/TASK-6 acceptance/E2E checks. Live transport evidence: source sequence 23 admitted, target delivery ACKed, and the full follow-up brief returned without pane injection.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Produced and independently delivered an implementation-ready actor UX contract covering every communication state, canonical replay/dedupe, truthful topic-backed status, responsive theme-aware Pi TUI layouts, accessibility, redaction, bounds, and E2E acceptance. Verified by the complete ActorTaskCompleted report returned over the owned actor path.
<!-- SECTION:FINAL_SUMMARY:END -->
