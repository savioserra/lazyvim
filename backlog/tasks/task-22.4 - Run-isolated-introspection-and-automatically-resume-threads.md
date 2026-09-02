---
id: TASK-22.4
title: Run isolated introspection and automatically resume threads
status: In Progress
assignee:
  - '@pi'
created_date: '2026-09-02 06:10'
updated_date: '2026-09-02 10:02'
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

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Bind the configured isolated runner to every restored/created hosted AgentActor and persist exact attempt identity before process spawn.\n2. Validate settlement against active thread/epoch/lease/turn/delivery, persist worker result, and classify completed/continue/waiting/blocked with strict runner output.\n3. Persist outcome before ActorTaskCompleted, resume dispatch, wait/block projection, retry, exhaustion, or source-commit compaction effects.\n4. Redrive settled/introspecting/resumable/completion state across restart and reconnect; dedupe duplicate settlement and completion commits.\n5. Add completed/continue/waiting/blocked/failure/exhaustion/restart and sent-elsewhere policy tests, then run full gates and live push-only Ask proof.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Live Ask 90 exposed the failure mode: its Ask completion first returned only `reconnaissance sent to client`; the full report arrived later as a separate hosted-bridge Tell. The PM initially lacked the payload, then received and processed it out of band. Thread completion must evaluate the requested deliverable and preserve it in-thread instead of treating an acknowledgement to a second message as completion.

Initial implementation landed during the TASK-22.3 integration gate: isolated runner injection, durable attempt identity/result/checkpoint, completed/continue/waiting/blocked/exhaustion transitions, exact active tuple validation, source commit handshake, and cross-node completion tests are present in a635864..b34944b. TASK-22.4 now focuses on the remaining deterministic state/policy/restart tests and live proof.

Added deterministic classification tests for completed, continue/resumable, waiting, blocked, and acknowledgement/sent-elsewhere rejection. Completed classification now independently rejects bounded acknowledgement/pointer worker results and resumes the same thread with a direct-deliverable prompt. Duplicate exact settlement is asserted idempotent with a counting runner (one introspection only). Remote bridge ACK test now retries explicit durable-busy responses instead of losing settlement evidence.

Added restart recovery proof for both settled and in-flight introspecting threads: restored actors redrive the same bounded task/worker/checkpoint input, retained attempts remain deterministic, and backoff reaches the configured five-minute cap. The source-commit handshake keeps thread completion pinned until durable source acknowledgement and only then compacts to a bounded terminal tombstone.
<!-- SECTION:NOTES:END -->
