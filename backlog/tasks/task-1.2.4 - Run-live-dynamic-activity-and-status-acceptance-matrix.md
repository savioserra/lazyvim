---
id: TASK-1.2.4
title: Run live dynamic activity and status acceptance matrix
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 05:40'
updated_date: '2026-09-02 13:08'
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

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
QA Ask 86 ran from a stale worktree and old productive-phase scope, so it is not an acceptance result for the current opaque dynamic-activity architecture. Discard as superseded: WorkflowActor/productive-phase fields, fixed phase revisions/worker-reviewer enums, legacy tmux-subagents state-to-phase inference as TASK-1.2 authority, and actor_tell-to-Ask mismatch (fixed on current main and live sequences 68-70). Retain baseline evidence only: generic roster epoch/sequence fencing and public-view sanitization pass; TASK-1.2.1 activity topic is not implemented yet; fresh process/high-water/reconnect service tests pass; real tmux remains environment-blocked by snap confinement. Final matrix must run from fresh current main after TASK-1.2.1-.3 and TASK-22 priority work.

QA acceptance matrix frozen: push-only changed/cleared activity plus pending Ask/lifecycle/role independence, live footer/overlay narrow-wide rerender/disposal, exact-owned tmux metadata with foreign pane unchanged, and audit against polling/scraping/injection/private leakage/duplicates.
<!-- SECTION:NOTES:END -->
