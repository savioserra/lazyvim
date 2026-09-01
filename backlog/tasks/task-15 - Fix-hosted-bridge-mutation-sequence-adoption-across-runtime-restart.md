---
id: TASK-15
title: Fix hosted bridge mutation sequence adoption across runtime restart
status: In Progress
assignee:
  - '@pi'
created_date: '2026-09-01 23:14'
updated_date: '2026-09-01 23:37'
labels: []
dependencies: []
modified_files:
  - home/dot_pi/private_agent/extensions/hosted-pi-bridge/mutations.ts
  - home/dot_pi/private_agent/extensions/hosted-pi-bridge/index.ts
  - services/subagents/internal/actors/agent.go
priority: high
type: bug
ordinal: 15000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Hosted Pi runtimes restart with their extension-local ClientMutationSequencer high-water at zero while the durable AgentActor retains the previous source mutation namespace. The first new actor-tell reuses sequence 1 and fails with source mutation sequence collision, preventing agents from reporting completion or discussing work without terminal-pane inspection. This is a release blocker for autonomous completion delivery.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A fresh hosted bridge process re-handshakes and adopts an authoritative next mutation sequence (or an equivalently fenced new namespace) before issuing any actor message
- [ ] #2 Runtime restart, daemon restart, and bridge reconnect each permit the first and consecutive actor-tell operations without collision
- [ ] #3 Immutable replay, concurrent-send serialization, exactly-once admission, and fail-closed identity checks remain intact
- [ ] #4 Regression covers a durable prior sequence, fresh extension sequencer, re-handshake/adoption, and a different next payload
- [ ] #5 Live E2E bounces the worker runtime and delivers its actor-tell report to Project Manager automatically without pane inspection
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Audit bridge connect/reconnect protocol and mutation-scope high-water retention for hosted actor messages. 2. Add authenticated authoritative message mutation high-water to BridgeConnectResponse and service/application mapping. 3. Teach hosted-pi-bridge ClientMutationSequencer to adopt server high-water before actor message allocation while preserving immutable replay/concurrent serialization. 4. Add focused daemon/extension tests for fresh process after retained sequence, consecutive/concurrent sends, reconnect replay, daemon restart, and runtime bounce where practical. 5. Run focused/full gates available, update TASK-15, report in pane and attempt actor-tell without commit/push/deploy.

6. Fix hosted-pi-bridge target attachment fences to request minimal per-operation capabilities, cache fences by target plus capability set, and add fresh-process regression for messaging-only agents plus control authorization behavior.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented authoritative hosted bridge actor-message high-water adoption. Daemon BridgeConnect/BridgeReplace now return ActorMessageHighWater computed from retained source actor outbox/history/completions; protobuf and generated Go/TS artifacts regenerated; hosted-pi-bridge adopts that high-water on initial connect/reconnect before allocating actor messages and records a bounded payload-free diagnostic. Added sequencer adoption regression and daemon/service coverage proving retained prior sequence -> fresh bridge connect high-water -> next different payload succeeds while stale sequence still fails closed. Validation: services/subagents ./tools/codegen.sh verify; go test -race ./...; go vet ./...; npm test; NODE_OPTIONS='--import ./services/subagents/node_modules/tsx/dist/loader.mjs' node --test tests/hosted-pi-bridge/*.mjs; NODE_OPTIONS='--import ./services/subagents/node_modules/tsx/dist/loader.mjs' node --test tests/actor-client/*.mjs; git diff --check. No commit/push/deploy. Live E2E awaits PM deploy.

Actor-tell evidence: attempted PM report to client:01a04959-c544-7a2a-8533-1031c0b36c56 from the still-running pre-fix worker runtime; it failed with the known sequence-1 collision. This is expected until PM deploys/restarts onto the fixed bridge handshake. Pane/final report carries implementation evidence.

Post-review hardening: accepted immutable replay no longer lowers a scope if reconnect adoption has already observed a higher authoritative high-water. Re-ran hosted-pi-bridge node tests via tsx loader: 35/35 pass; git diff --check remains clean.

Live attach fix: hosted-pi-bridge now requests operation-minimal target fences (tell=observe+send, ask=observe+ask, abort/shutdown=observe+specific control), caches by target plus normalized capability set so messaging fences are not reused for control, and preserves the self bridge fence separately for hosted bridge lifecycle/polling. Added hosted bridge regression for capability-set scoped keys and absence of overbroad control capabilities in actor_tell. Validation: NODE_OPTIONS='--import ./services/subagents/node_modules/tsx/dist/loader.mjs' node --test tests/hosted-pi-bridge/*.mjs (36/36 pass); git diff --check.
<!-- SECTION:NOTES:END -->
