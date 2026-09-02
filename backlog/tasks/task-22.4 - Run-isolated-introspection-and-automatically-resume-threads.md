---
id: TASK-22.4
title: Run isolated introspection and automatically resume threads
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 06:10'
updated_date: '2026-09-02 06:14'
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
- [ ] #5 Introspection does not mark a request complete when its terminal answer is only an acknowledgement or sent-elsewhere pointer; required deliverables remain linked to the same durable thread and the requesting Ask receives the bounded completion result exactly once
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Live Ask 90 exposed the failure mode: its Ask completion first returned only `reconnaissance sent to client`; the full report arrived later as a separate hosted-bridge Tell. The PM initially lacked the payload, then received and processed it out of band. Thread completion must evaluate the requested deliverable and preserve it in-thread instead of treating an acknowledgement to a second message as completion.
<!-- SECTION:NOTES:END -->
