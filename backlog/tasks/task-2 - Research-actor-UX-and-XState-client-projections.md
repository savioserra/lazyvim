---
id: TASK-2
title: Research actor UX and XState client projections
status: In Progress
assignee:
  - '@pi'
created_date: '2026-08-31 21:41'
updated_date: '2026-09-02 01:06'
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
- [ ] #1 Defines compact Tell, Ask, completion, failure, busy, and replay-deduped conversation-card states
- [ ] #2 Defines responsive narrow and wide layouts using Pi theme tokens without fixed transcript widgets
- [ ] #3 Defines truthful topic-backed status semantics without polling actor_list or inferring productivity from liveness
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Audit the current actor-client status line, communication cards, Pi TUI primitives, and ADR constraints.
2. Specify user journeys, information hierarchy, state transitions, narrow/wide behavior, accessibility, and redaction.
3. Return an implementation matrix and critique the proposed XState projection boundaries.
<!-- SECTION:PLAN:END -->
