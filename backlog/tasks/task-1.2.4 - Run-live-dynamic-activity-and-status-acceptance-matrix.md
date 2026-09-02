---
id: TASK-1.2.4
title: Run live dynamic activity and status acceptance matrix
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 05:40'
updated_date: '2026-09-02 05:40'
labels: []
dependencies:
  - TASK-1.2.2
  - TASK-1.2.3
  - TASK-1.1
  - TASK-19
  - TASK-20
references:
  - docs/architecture/subagents/ACTOR-UX-DESIGN-SYSTEM.md
  - docs/architecture/subagents/ROADMAP.md
parent_task_id: TASK-1.2
priority: high
type: task
ordinal: 33000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deploy the activity/status slices and prove realtime footer, interactive overlay, and exactly owned hosted UI from fresh terminal and hosted Pi processes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Fresh-process E2E publishes unknown, labeled, changed, and cleared activities and observes immediate footer/overlay updates without manual refresh
- [ ] #2 Role and lifecycle changes remain independent, stale frames are invisible, reconnect/reset restores one current snapshot, and pending Ask status composes without duplication
- [ ] #3 Interactive overlay remains responsive and bounded at narrow/wide widths while updates arrive and closes without leaking subscriptions or focus
- [ ] #4 Hosted owned title/border/status follows owner topic while a foreign/indeterminate pane is proven unchanged
- [ ] #5 Traffic/log audit proves no actor_list polling, terminal scraping, pane injection, private-field leakage, duplicate cards, or authority mutation
<!-- AC:END -->
