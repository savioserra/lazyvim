---
id: TASK-22.3
title: Persist AgentActor thread aggregate and fair scheduler
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 06:10'
labels: []
dependencies:
  - TASK-22.2
parent_task_id: TASK-22
priority: high
type: feature
ordinal: 38000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Persist target-authoritative thread records and a one-active-thread scheduler so later admitted tasks queue without overwriting unfinished work.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Exact duplicate admission converges on one thread and immutable mismatch fails closed
- [ ] #2 Thread and scheduler state commits before acceptance, dispatch, status, or completion effects
- [ ] #3 Queue, resumable, waiting, blocked, terminal tombstone, bounds, fairness, migration, crash, restart, and race tests pass
<!-- AC:END -->
