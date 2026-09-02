---
id: TASK-6
title: Review and QA gates for UI slice
status: To Do
assignee:
  - '@pi'
created_date: '2026-08-31 21:41'
updated_date: '2026-09-02 01:06'
labels: []
dependencies:
  - TASK-5
priority: high
type: task
ordinal: 6000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Perform independent architecture review and QA of the XState projection and rich Pi TUI slice before deployment.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Reviewer verifies authority boundaries, deterministic reducers, exact-once rendering, and redaction
- [ ] #2 QA verifies reconnect/replay, stale cursors, Tell/Ask/completion cards, busy/failure states, and narrow/wide rendering
- [ ] #3 All actor-client, hosted bridge, codegen, Go, formatting, and dry-run apply gates pass or have documented environment-only blockers
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Conduct read-only architecture and security review.
2. Execute focused projection/widget tests and full relevant gates.
3. Return findings to the implementation writer for fixes; repeat until clean.
4. Perform local reload and live actor conversation E2E before finalization.
<!-- SECTION:PLAN:END -->
