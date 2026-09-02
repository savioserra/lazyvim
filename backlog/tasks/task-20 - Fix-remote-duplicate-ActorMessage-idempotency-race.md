---
id: TASK-20
title: Fix remote duplicate ActorMessage idempotency race
status: In Progress
assignee:
  - '@pi'
created_date: '2026-09-02 04:30'
updated_date: '2026-09-02 05:35'
labels: []
dependencies: []
references:
  - services/subagents/internal/service/remote_hosted_integration_test.go
  - services/subagents/internal/service/service.go
priority: high
type: bug
ordinal: 23000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A full `go test -race ./...` run intermittently failed `TestRemoteHostedOrdinaryServicePath/remote_duplicate_actor_message_is_idempotent`: the first duplicate Tell returned accepted/stored_pending_credit while the same request returned source mutation sequence must advance exactly once. Immediate rerun passed, indicating an ordering/authority race in remote forwarding, request-result dedupe, or source admission visibility. Preserve fail-closed sequence validation while making identical remote request identity/digest return one authoritative retained result.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Concurrent and sequential duplicate remote ActorMessage requests with identical request ID, mutation sequence, and payload digest return the same authoritative admission/result
- [ ] #2 A different payload or identity reusing the request/mutation identity still fails closed as a collision
- [ ] #3 Idempotency survives placement forwarding and relevant node/session reconnect or restart boundaries without dual admission
- [ ] #4 The remote duplicate regression passes repeatedly under race detection and the full service gate is stable
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reproduce the remote duplicate Tell race and distinguish request-router dedupe, forwarding placement, source AgentActor admission, and test attach setup failures.
2. Make identical request/mutation identity plus payload digest converge on one retained or in-flight authoritative result before dense sequence rejection; preserve loud failure for payload/identity collision.
3. Ensure remote forwarding retries and concurrent duplicates cannot bypass the single source-owner idempotency boundary or admit twice.
4. Add deterministic concurrent/sequential/reconnect regressions and stabilize authorization setup.
5. Run focused tests repeatedly under race detection and the full service/repository gates.

6. Close the terminal-history gap before integration: retain a durable immutable source mutation fingerprint and authoritative receipt across target acceptance/outbox retirement and terminal completion; include request, dedupe, chain, sequence, target, mode, capability, and payload digest.
7. Prove identical and changed-payload duplicates both before completion and after terminal retention/restart, including legacy records whose fingerprint cannot be proven.

8. Pin active accepted receipts: eviction may remove only terminal receipts. Before a new admission, if the bounded receipt set is full and every entry is active, return explicit backpressure before mutating high-water/outbox/durable state.
9. Test >retention-limit active admissions, terminal-first eviction, duplicate replay at capacity, restart restoration, and capacity recovery after terminal completion.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Independent QA sequence 56 reproduced the release blocker on origin/main 89e77ee: first remote duplicate response accepted/stored_pending_credit, second identical response rejected source mutation sequence must advance exactly once. A focused attempt also exposed intermittent attach authorization setup failure. TASK-20 blocks deployment of the Tell/Ask UX change.

Writer sequence 60 produced commit 9c08c38 with pending/in-flight duplicate convergence, collision rejection, fixture stabilization, concurrent remote tests, and reported focused -race count=20/full gates. Not integrated or finalized pending independent review sequence 63, specifically terminal sourceTaskHistory digest fencing, post-restart behavior, legacy zero-digest history, and complete immutable identity comparison.

PM code audit of a21b62b found the implementation only validates payload while sourceOutbox is retained. Exact sourceTaskHistory matches return terminal results without digest comparison, and sameSourceOutboxMutation omits dedupe/chain checks. A post-terminal changed-payload regression is required before integration.

Independent review sequence 63 rejected 9c08c38/a21b62b with two High findings: terminal sourceTaskHistory replays before comparing immutable fingerprint and actorTaskID omits request ID; sameSourceOutboxMutation omits dedupe/chain. Medium test gap: no post-terminal, restart, changed-request, changed-dedupe/chain, or exactly-once placement delivery proof; shared remote fixture also weakens isolation. These findings match the PM audit and are mandatory inputs to correction sequence 64.

Corrected writer implementation integrated on main as 88d603c and 013adc7. Durable SourceMutationReceipts now retain full request/dedupe/chain/sequence/target/mode/capability/payload fingerprint plus authoritative result across outbox retirement and terminal/restart; legacy digest-less history fails closed. PM verification passed actor receipt -race count=20, state bound -race count=20, remote duplicate/concurrent -race count=20, hosted gateway -race count=20, full codegen/go race/vet/protocol, actor/bridge 79/79, capabilities, diff, and scratch apply. Independent final review sequence 66 remains open; task not finalized.

Final independent review sequence 66 closed all prior High findings but rejected final approval on one Medium issue: retainSourceMutationReceipt blindly FIFO-evicts accepted AwaitingAck receipts at maxCommandResults. An active receipt must remain replayable until terminal; boundedness requires terminal-only eviction plus admission backpressure when every retained receipt is active.
<!-- SECTION:NOTES:END -->
