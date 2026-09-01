---
id: TASK-11
title: >-
  Fix actor-task outbox credit churn: spend held credit, single-flight credit
  requests, bounded reject logging
status: Done
assignee:
  - '@shyylol'
created_date: '2026-09-01 00:20'
updated_date: '2026-09-01 00:34'
labels: []
dependencies: []
priority: high
type: bug
ordinal: 11000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
PM directive TASK-9b. Live evidence: outbox retries re-request credit while the item already holds an unexpired granted credit (credit_id rotates each tick, target TaskCreditEpoch climbs ~5/sec) so ActorTask Tells carry stale-epoch credits and are silently rejected; daemon logs nothing. Fix in services/subagents/internal/actors/agent.go: (1) retrySourceOutbox sends the task with a held unexpired+unconsumed credit and re-requests only when the credit is missing or expired; (2) one in-flight credit request per outbox item (bounded await window) so overlapping retries cannot churn the target epoch; (3) target-side bounded reject logging for ActorTask with epoch/expiry/sender/digest reasons; (4) complete the pending resumePendingWork restore re-drive wiring. Tests: held-credit send regression, stale backpressure must not churn epoch, single-flight against slow target, exactly-once delivery against slow target, stale-epoch/consumed-credit regression, bounded reject logging. Gates: go test -race, go vet, codegen verify, node suites.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 retrySourceOutbox spends a held unexpired credit (state label ignored) and re-requests only when the credit is missing or expired — proven by TestOutboxHeldUnexpiredCreditIsSentNotReRequested failing on pre-fix code
- [x] #2 One in-flight credit request per outbox item with a bounded await window — proven by TestOutboxCreditRequestIsSingleFlightWhileGrantAwaited (2 overlapping requests pre-fix, exactly 1 fixed)
- [x] #3 Stale TaskBackpressured no longer churns the target credit epoch — proven by TestStaleBackpressureMustNotChurnTargetCreditEpoch (max_epoch=2, reservations=2 pre-fix; exactly 1 and 1 fixed)
- [x] #4 Overlapping retries against a slow target deliver exactly once with exactly one credit epoch and one commit — proven by TestSlowTargetDeliversActorTaskExactlyOnce
- [x] #5 Target-side bounded reject logging with epoch/expiry/sender/digest reasons, capped at 32 lines, and stale-epoch/consumed-credit Tells rejected without double delivery — proven by TestActorTaskRejectLoggingIsBoundedAndSpecific
- [x] #6 resumePendingWork restore re-drive wiring completed (field declared and consumed by restoreDurableTimers)
- [x] #7 Gates green: go test -race ./..., go vet ./..., codegen verify, npm test (subagents); environmental-only failures documented (tmux binary absent)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Complete pending resumePendingWork field wiring (compile fix). 2. retrySourceOutbox: send ActorTask with held unexpired credit regardless of state label; re-request only when missing/expired. 3. Add bounded single-flight credit-request await map per outbox item; clear on grant/backpressure/retirement; bounded re-request window for lost grants; schedule retry loop on fresh admission. 4. Target-side bounded reject logging in actorTask with epoch/expiry/sender/digest detail. 5. Regression tests: held-credit send, stale-backpressure no-churn, single-flight slow target, exactly-once delivery, stale-epoch reject, bounded log. 6. Full gates.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation (services/subagents/internal/actors/agent.go): retrySourceOutbox now sends the ActorTask whenever item.Credit is non-empty and unexpired, regardless of the pending_credit/sent state label (a stale TaskBackpressured reply no longer discards a live credit); re-request happens only when the credit is missing or expired. Single-flight: new in-memory outboxCreditAwaited map (taskID -> request time) marked in requestOutboxCredit and enforced in retrySourceOutbox with taskCreditRequestTimeout=500ms (well under the 5s credit lease, so a lost grant re-requests without ever overlapping a live one); cleared on valid grant, backpressure, acceptance, and deadline retirement. Fresh admissions now schedule their own bounded retry loop via scheduleOutboxRetry instead of waiting for a restart. Target side: actorTask rejects now emit one bounded operator line (maxActorTaskRejectLogs=32) via logActorTaskReject with agent/task/credit atoms, message epoch, current target epoch, reserved epoch, expiry, sender-identity verdict, and a specific reason tag (credit_reservation_missing/credit_epoch_mismatch/payload_digest_mismatch/credit_expired/credit_digest_mismatch/credit_task_mismatch/sender_identity_rejected); taskRejectLog field is the test seam, nil falls back to stderr. resumePendingWork declared and consumed by restoreDurableTimers (completes the previously non-compiling working-tree hunk).
Validation: new tests in agent_task_outbox_credit_test.go and agent_task_reject_log_test.go. Pre-fix reversion reproduced all three live failure signatures (held credit never sent; 2 overlapping credit requests; stale backpressure churning target epoch to 2 with 2 reservations). Gates: go test -race ./... ok (actors 23.1s, service 29.8s, repeated 3x for flake check), go vet ./... ok, tools/codegen.sh verify ok, npm test 6/6 ok, nvim -l tests/capabilities.test.lua ok, stylua --check ok, git diff --check ok. Environmental (pre-existing, unrelated to this Go-only change; tmux binary absent on this host): 4/97 tests/tmux-subagents node tests fail with 'spawn tmux ENOENT', and chezmoi apply --dry-run aborts in dot_config/private_workstation/private_subagents/private_config.toml.tmpl at the 'command -v tmux' probe. No commit/push/deploy performed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Fixed actor-task outbox credit churn per PM directive TASK-9b: held unexpired credits are now spent instead of re-requested, credit requests are single-flight per outbox item (bounded 500ms await), fresh admissions own their retry loop, and target-side ActorTask rejects are logged with epoch/expiry/sender/digest detail, bounded to 32 lines. Verified with 5 new regression tests (three of which reproduce the live failure signatures on pre-fix code) plus full race/vet/codegen/node gates; tmux-dependent checks fail only for the absent tmux binary on this host.
<!-- SECTION:FINAL_SUMMARY:END -->
