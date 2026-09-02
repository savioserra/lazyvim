---
id: TASK-22.5
title: Project thread status and prove A-B-resume-A E2E
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 06:10'
updated_date: '2026-09-02 13:09'
labels: []
dependencies:
  - TASK-22.4
  - TASK-1.2.1
parent_task_id: TASK-22
priority: high
type: task
ordinal: 40000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Expose bounded owner-private thread status through the activity projection and prove a fresh hosted actor returns to unfinished task A after processing task B.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Owner-private status shows opaque thread state without payload/model/runtime/tmux details and public surfaces remain unchanged
- [ ] #2 Fresh-process E2E forces task A incomplete, admits task B, completes B, automatically resumes A, and completes both exactly once without reminders or pane inspection
- [ ] #3 Daemon/runtime restart and compaction variants of the E2E pass with sanitized evidence
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Adopted sanitized A→B→resume-A acceptance sequence from UI/UX review: A accepted/resumable, B accepted/completed once, A automatic resume/completed once, including fresh process, daemon/runtime restart, and compaction; no reminder, pane inspection, actor_list polling, duplicate completion, or private leakage.

Current thread-architect review confirms no owner-private status topic/replay and no fresh A→B→resume-A proof. It also found the remaining internal RemoteBridgeIntent/raw BridgeIntent model-bearing bypass; TASK-22.5 is not integration-ready until this authority gap and TASK-1.2.1 projection are complete.
<!-- SECTION:NOTES:END -->
