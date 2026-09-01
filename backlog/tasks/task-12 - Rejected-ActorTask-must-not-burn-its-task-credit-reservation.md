---
id: TASK-12
title: >-
  Rejected ActorTask must not burn its task credit reservation (PM addendum
  TASK-12b)
status: Done
assignee:
  - '@pi'
created_date: '2026-09-01 21:48'
updated_date: '2026-09-01 21:51'
labels: []
dependencies: []
priority: high
type: bug
ordinal: 12000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Live blocker (journal: credit_reservation_missing rejects ~5/sec against idle targets, epoch ~13800). Root cause: AgentActor.actorTask deletes the taskCreditReservations entry before acceptActorTaskWithCredit decides; when acceptance fails (bridge not ready, capacity, duplicate, prompt conflict), the credit is consumed while the source outbox item still holds it and redrives it, so every redrive rejects as credit_reservation_missing. Fix so a granted reservation survives until its 5s lease expiry or successful consumption; regression test reproducing grant->task with interleaved credit requests from the same source to other targets.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A granted task credit reservation survives rejected ActorTask deliveries (bridge not ready, capacity, duplicate, prompt conflict) and interleaved credit requests from the same source, until its 5s lease expiry or successful consumption
- [x] #2 A successful acceptance consumes the reservation exactly once: duplicate redelivery of the same credited task rejects as a stale credit and delivers exactly once
- [x] #3 Regression test reproduces grant -> interleaved credit requests (other items on the same target and items on other targets) -> task delivery -> reject -> redrive and asserts the reservation is retained
- [x] #4 Focused gates pass: go test -race ./..., go vet ./..., tools/codegen.sh verify, npm test in services/subagents
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reproduce red: probe-driven grant->rejected-task->redrive shows stale-credit reject instead of acceptance reject. 2. Fix actorTask to restore the reservation when acceptActorTaskWithCredit fails so it survives until lease expiry or successful consumption. 3. Regression tests: interleaved credit requests (same source, other targets and same target), reservation retained on reject, consumed on acceptance. 4. Focused gates: go test -race ./..., go vet ./..., codegen verify.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Investigation: requestTaskCredit only expires stale reservations and adds new ones (no per-source or global sweep); expireTaskCredits is keyed by CreditID and checks ExpiresAt correctly; restoreDurableState preserves persisted reservations (a respawn would reject sender_identity_rejected, not reservation_missing). Actual killer: actorTask deleted the reservation BEFORE acceptActorTaskWithCredit decided, so a refused task (bridge not ready, capacity, duplicate, prompt conflict) burned the credit while the source outbox item still held it; retrySourceOutbox redrove the dead credit until lease expiry, logging credit_reservation_missing ~5/sec and rotating one epoch per lease cycle. Fix (6 lines): re-add the reservation when acceptActorTaskWithCredit fails, so it survives until lease expiry or successful consumption. Red confirmed pre-fix (redrive answered 'invalid, expired, duplicate, or stale task credit'), green post-fix (redrive answers the real refusal 'actor task rejected').

Validation: go test -race ./... ok (internal/actors 22.5s incl. new agent_task_credit_reservation_test.go), go vet ./... clean, tools/codegen.sh verify pass 6/fail 0, npm test pass 6/fail 0. No commit/push/deploy per task instructions.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Fixed TASK-12b blocker: AgentActor.actorTask consumed the task credit reservation before acceptActorTaskWithCredit decided, so refused tasks (idle/unbridged target) burned the credit and every outbox redrive rejected as credit_reservation_missing (~5/sec, one epoch rotation per 5s lease) matching the live journal signature. The reservation is now restored when acceptance fails, surviving until lease expiry or successful consumption (acceptance still consumes exactly once). Added agent_task_credit_reservation_test.go: interleaved-credit-request regression (grant -> other-target and same-target requests -> rejected delivery -> redrive retains reservation with the real refusal reason) plus consumption-on-success pin (duplicate redelivery rejects as stale credit, exactly one delivery). Verified: reproduction red pre-fix, green post-fix; go test -race ./..., go vet ./..., codegen verify, npm test all pass.
<!-- SECTION:FINAL_SUMMARY:END -->
