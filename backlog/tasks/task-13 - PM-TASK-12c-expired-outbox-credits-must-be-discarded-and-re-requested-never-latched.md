---
id: TASK-13
title: >-
  PM TASK-12c: expired outbox credits must be discarded and re-requested, never
  latched
status: Done
assignee:
  - '@pi'
created_date: '2026-09-01 22:16'
updated_date: '2026-09-01 22:20'
labels: []
dependencies: []
priority: high
type: bug
ordinal: 13000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
PM follow-up after 43a0079: live stuck state — all outbox items state=sent with credits expired at 18:52 (observed 19:09+), attempts climbing ~4/sec (414+), zero actor-task rejects and zero credit requests reaching targets (no epoch churn, target queues 0, worker cursor static). PM hypothesis: single-flight outboxCreditAwaited latch never cleared on credit expiry or daemon-restart spawn/restore, or expiry check uses wrong field. Fix: on retry tick, an expired item credit clears the awaited latch, discards the credit (State back to pending_credit), and re-requests on that tick; single-flight clears on expired-grant arrival and on restoreDurableState; verify grant->send->accept for a previously-latched item; regression for expired credit + awaited latch restored from durable state. NOTE: latch is in-memory only in current code (not durable) — report documents the discrepancy.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Retry tick discards an expired held outbox credit durably (CreditID cleared, State=pending_credit persisted) and re-requests credit on that same tick
- [x] #2 Awaited single-flight latch is cleared on expired/refused grant arrival, on held-credit expiry, and on restoreDurableState (spawn/rollback/reload)
- [x] #3 Regression: item restored from durable state with expired credit + state=sent re-requests, and grant->send->accept completes (commit published)
- [x] #4 Existing TASK-11/12 outbox behavior preserved (held unexpired credit is spent, not re-requested); focused gates pass: go test -race ./..., go vet ./..., codegen verify, npm test
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reproduce live state in regression tests (item restored with expired credit + state=sent; awaited latch): red assertions on HEAD for credit discard, state label, latch clearing on expired grant. 2. Fix retrySourceOutbox: expired held credit -> clear outboxCreditAwaited latch, discard credit, State=pending_credit, persist, re-request on same tick. 3. Fix taskCreditGranted guard: clear latch when a grant is rejected (expired/deadline/digest). 4. Clear latch in restoreDurableState (spawn/rollback/reload). 5. Verify grant->send->accept end-to-end for previously-latched item in tests. 6. Focused gates: go test -race ./..., go vet ./..., tools/codegen.sh verify, npm test. 7. Report via actor-tell to Project Manager incl. durable-latch discrepancy findings.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Investigation findings vs PM hypotheses: (1) outboxCreditAwaited is IN-MEMORY ONLY (map[string]time.Time, never in durableState/restoreDurableState) — a daemon restart CANNOT restore/latch it from durable state; after respawn the latch map is fresh. (2) The awaited check is time-bounded (taskCreditRequestTimeout=500ms), so within a live process the latch alone cannot suppress re-requests forever. (3) The expiry check DOES use the correct field (item.Credit.ExpiresAt vs now) — no lease/timestamp mixup found. What IS real and fixed: an expired held credit was never discarded (durable items carried dead credit ids/state=sent forever — matches live 'credit ids stale, state=sent' evidence), the latch stayed set for the window's remainder after a refused/expired grant, and restoreDurableState did not reset the latch on rollback/reload paths (only spawn constructed it fresh). Residual live-stuck risk NOT covered by this fix: if zero credit requests reach targets while attempts climb, the retry loop can only be idling in the target==nil branch (resolveActorRefAsync -> continue) — i.e. TargetRef host/port/name no longer resolving (e.g. remote daemon restarted on a different port; lookupActorRef never re-resolves remote refs by logical agent id, only by recorded host:port, and the stable-name fallback only runs in the local branch). Recommend the PM capture the source agent's resolve logs if the stuck state persists after this fix lands.

PM report delivery blocked: actor-tell to client:01a04959-c544-7a2a-8533-1031c0b36c56 failed deterministically (2/2 attempts) with the TASK-8 known-limit sequencer collision: 'client mutation sequence failed for scope hosted-session-_OzGuFjwtfBu-xXWllVHKLdJspVL6-YfIxZO5cMQgrQ hosted-generation-_OzGuFjwtfBu-xXWllVHKLdJspVL6-YfIxZO5cMQgrQ hosted:task_credit_impl_worker task_credit_impl_worker messages at sequence 1: source mutation sequence collision'. Matches the flagged fresh-bridge-restarts-at-1 vs daemon-retained-high-water gap awaiting the PM decision/ADR-0005 daemon-side fix. Exact text handed to the user for relay.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Fixed PM TASK-12c: retrySourceOutbox now discards a held credit past its lease (durable CreditID cleared, State=pending_credit, latch ended) and re-requests on the same tick; taskCreditGranted clears the single-flight latch when a grant is refused (expired lease/deadline/digest); restoreDurableState resets outboxCreditAwaited so rollback/reload can never inherit a latch. Regressions in agent_task_outbox_expiry_test.go: (1) item restored with expired credit + state=sent is discarded durably, re-requests, and completes grant->send->accept with commit published — RED pre-fix (dead credit retained forever, matching live stale-credit-ids evidence), GREEN post-fix; (2) expired grant clears the awaited latch so the next tick re-requests inside the 500ms window — RED pre-fix, GREEN post-fix. Investigation disproved the durable-latch hypothesis: outboxCreditAwaited is in-memory only and 500ms-bounded; no ExpiresAt/lease field mixup exists. Residual risk flagged to PM: attempts climbing with zero requests reaching targets can only idle in the target==nil resolution branch; remote refs whose host:port rotted across a daemon restart are never re-resolved by logical agent id (stable-name fallback is local-branch only). Gates: go test -race ./... PASS, go vet ./... clean, tools/codegen.sh verify PASS, npm test 6/6, git diff --check clean; existing TASK-11/12 outbox suites unchanged-green. No commit/push/deploy.
<!-- SECTION:FINAL_SUMMARY:END -->
