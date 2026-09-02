---
id: TASK-20
title: Fix remote duplicate ActorMessage idempotency race
status: In Progress
assignee:
  - '@pi'
created_date: '2026-09-02 04:30'
updated_date: '2026-09-02 04:52'
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
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Independent QA sequence 56 reproduced the release blocker on origin/main 89e77ee: first remote duplicate response accepted/stored_pending_credit, second identical response rejected source mutation sequence must advance exactly once. A focused attempt also exposed intermittent attach authorization setup failure. TASK-20 blocks deployment of the Tell/Ask UX change.

Writer sequence 60 produced commit 9c08c38 with pending/in-flight duplicate convergence, collision rejection, fixture stabilization, concurrent remote tests, and reported focused -race count=20/full gates. Not integrated or finalized pending independent review sequence 63, specifically terminal sourceTaskHistory digest fencing, post-restart behavior, legacy zero-digest history, and complete immutable identity comparison.
<!-- SECTION:NOTES:END -->
