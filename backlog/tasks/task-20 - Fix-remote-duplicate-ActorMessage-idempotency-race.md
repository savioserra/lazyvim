---
id: TASK-20
title: Fix remote duplicate ActorMessage idempotency race
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 04:30'
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
