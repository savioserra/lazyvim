---
id: TASK-22.4
title: Run isolated introspection and automatically resume threads
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 06:10'
labels: []
dependencies:
  - TASK-22.3
parent_task_id: TASK-22
priority: high
type: feature
ordinal: 39000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
After the exact active thread turn settles, run isolated structured introspection and either complete, resume, wait, block, or exhaust the thread through durable scheduler transitions.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Duplicate agent_end/agent_settled cannot introspect or complete a thread twice
- [ ] #2 Continue automatically resumes from the durable checkpoint under bounded fairness/backoff; waiting and blocked never spin
- [ ] #3 Only a validated high-confidence completed result for the exact active lease can lead to one ActorTaskCompleted after persistence
- [ ] #4 Malformed output, timeout, runtime restart, compaction, reconnect, deadline, and exhaustion fail closed and recover deterministically
<!-- AC:END -->
