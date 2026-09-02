---
id: TASK-4
title: Team discussion and design synthesis
status: To Do
assignee:
  - '@pi'
created_date: '2026-08-31 21:41'
updated_date: '2026-09-02 01:06'
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
- [ ] #1 Resolves researcher disagreements against ADR 0005 and the actor UX design system
- [ ] #2 Produces a file-level implementation contract, event catalog, selectors, widgets, and test matrix
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Cross-review TASK-2 and TASK-3 findings.
2. Resolve conflicts around authority, replay, status truthfulness, and transcript rendering.
3. Freeze a bounded implementation contract for TASK-5.
<!-- SECTION:PLAN:END -->
