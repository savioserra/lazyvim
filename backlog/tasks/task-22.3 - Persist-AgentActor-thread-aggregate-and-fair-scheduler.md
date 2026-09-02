---
id: TASK-22.3
title: Persist AgentActor thread aggregate and fair scheduler
status: Done
assignee:
  - '@pi'
created_date: '2026-09-02 06:10'
updated_date: '2026-09-02 09:56'
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
- [x] #1 Exact duplicate admission converges on one thread and immutable mismatch fails closed
- [x] #2 Thread and scheduler state commits before acceptance, dispatch, status, or completion effects
- [x] #3 Queue, resumable, waiting, blocked, terminal tombstone, bounds, fairness, clean-cutover, crash, restart, and race tests pass
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add bounded v3 thread/event/scheduler records and strict state validation; v2 is intentionally unsupported and deployment recreates every hosted runtime with clean v3 state.\n2. Integrate target-authoritative thread derivation, immutable fingerprint collision checks, exact replay receipts, and commit-before-ActorTaskAccepted in acceptActorTaskWithCredit.\n3. Add one-active scheduler state with injectable clock/backoff and deterministic two-new-task fairness; persist epoch/lease/queue decisions before bridge dispatch.\n4. Restore/redrive scheduler state across v3 restart, compact bounded event/tombstone history, and quarantine impossible references or oversize records.\n5. Add table, crash-point, clean-cutover, restart, fairness, and race tests; run full service and repository gates before finalization.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
QA reconnaissance Ask 100 froze the deterministic proof matrix and reusable seams: config/runner parser tables; atomic v2-to-v3 migration and quarantine; exact duplicate and collision admission; two-new-task fairness; injectable clock/backoff; ACK/settlement/introspection crash gates; restart/compaction redrive; owner-private projection; and push-only A-to-B-to-resume-A E2E with no BridgePollRequest or pane inspection. Existing bridge harnesses, blocking stores, ACK cursor/restart tests, and actor reply push tests should be reused.

Operator explicitly chose a clean v3 cutover instead of v2-to-v3 record migration. All six retained hosted sessions were explicitly stopped and recreated from clean state; v2 records will fail closed rather than migrate.

Implemented first scheduler aggregate slice: AgentActor persists/restores bounded thread records and scheduler sets; hosted Ask/Prompt admission derives target-authoritative thread IDs, converges exact replays, rejects immutable/source-sequence collisions, queues later prompts instead of overwriting active work, and persists scheduler epoch/lease before dispatch. Added deterministic two-new-task fairness and backoff selection. Thread ACK now atomically retains worker result/settlement without emitting ActorTaskCompleted; failed delivery becomes resumable. Strict state validation covers scheduler references, state sets, tombstones, bounds, and thread fingerprints. Focused actor/state race tests pass.

Implemented durable post-ACK thread execution: settlement commit now triggers isolated injected introspection only after persistence; attempt identity/state/result/checkpoint/digests are retained; completed classification preserves the worker answer in ActorTaskCompleted; continue becomes resumable with deterministic backoff; waiting/blocked remain inert; runner failure retries three times then exhausts fail-closed. Source ActorTaskCompleted received during another persistence transaction is locally redriven instead of dropped. Cross-node Ask completion, push/reconnect, full service, full Go race, vet, codegen, protocol, and capability suites pass.

Final TASK-22.3 evidence: deterministic identity/collision and fairness tests; strict persisted queue/resumable/waiting/blocked/tombstone validation; ACK settlement and worker-result tests; cross-node completion-to-source commit handshake with target tombstone compaction; clean v2 rejection; full go test -race ./..., go vet ./..., codegen verify, protocol npm test, capability tests, and live deployment checks.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Added schema-v3 durable AgentActor threads, exact target-authoritative admission, one-active fair scheduling, settlement persistence, bounded retry/backoff, restart restoration, source-commit tombstone compaction, and fail-closed validation. Verified with focused crash/replay/state tests, cross-node Ask completion, and full race/vet/codegen/protocol suites.
<!-- SECTION:FINAL_SUMMARY:END -->
