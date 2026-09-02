---
id: TASK-15
title: Fix hosted bridge mutation sequence adoption across runtime restart
status: In Progress
assignee:
  - '@pi'
created_date: '2026-09-01 23:14'
updated_date: '2026-09-02 00:56'
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
1. Move regular push authority to TargetTaskCommitted so target durable commit strictly precedes websocket push; test no pre-commit push and one post-commit push.\n2. Replace actor-client's fake immediate ACK with an exported regular-delivery coordinator: durable session-entry marker restoration, incoming cards, exactly-once followUp injection, prompt run correlation at agent_end/agent_settled, bounded real answer ACK, and terminal failure/deadline ACK.\n3. Wire session_start restoration and agent lifecycle callbacks without sharing mutable hosted-bridge authority.\n4. Add actor-client tell/ask/replay tests and service-level websocket push regression.\n5. Run full service, Go, TypeScript, repository fast gates; keep TASK-15 active and mark /reload required.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented authoritative hosted bridge actor-message high-water adoption. Daemon BridgeConnect/BridgeReplace now return ActorMessageHighWater computed from retained source actor outbox/history/completions; protobuf and generated Go/TS artifacts regenerated; hosted-pi-bridge adopts that high-water on initial connect/reconnect before allocating actor messages and records a bounded payload-free diagnostic. Added sequencer adoption regression and daemon/service coverage proving retained prior sequence -> fresh bridge connect high-water -> next different payload succeeds while stale sequence still fails closed. Validation: services/subagents ./tools/codegen.sh verify; go test -race ./...; go vet ./...; npm test; NODE_OPTIONS='--import ./services/subagents/node_modules/tsx/dist/loader.mjs' node --test tests/hosted-pi-bridge/*.mjs; NODE_OPTIONS='--import ./services/subagents/node_modules/tsx/dist/loader.mjs' node --test tests/actor-client/*.mjs; git diff --check. No commit/push/deploy. Live E2E awaits PM deploy.

Actor-tell evidence: attempted PM report to client:01a04959-c544-7a2a-8533-1031c0b36c56 from the still-running pre-fix worker runtime; it failed with the known sequence-1 collision. This is expected until PM deploys/restarts onto the fixed bridge handshake. Pane/final report carries implementation evidence.

Post-review hardening: accepted immutable replay no longer lowers a scope if reconnect adoption has already observed a higher authoritative high-water. Re-ran hosted-pi-bridge node tests via tsx loader: 35/35 pass; git diff --check remains clean.

Live attach fix: hosted-pi-bridge now requests operation-minimal target fences (tell=observe+send, ask=observe+ask, abort/shutdown=observe+specific control), caches by target plus normalized capability set so messaging fences are not reused for control, and preserves the self bridge fence separately for hosted bridge lifecycle/polling. Added hosted bridge regression for capability-set scoped keys and absence of overbroad control capabilities in actor_tell. Validation: NODE_OPTIONS='--import ./services/subagents/node_modules/tsx/dist/loader.mjs' node --test tests/hosted-pi-bridge/*.mjs (36/36 pass); git diff --check.

Idempotent target reattach fix: AgentActor AttachAgent now checks existing generation attachments before durable-busy/fence rotation. Same generation/principal with existing capabilities covering requested capabilities returns the persisted handle/fence without mutation or persistence; principal mismatch fails closed; broader capability requests continue to normal fenced replacement/busy behavior and do not silently broaden. Added TestAttachAgentIdempotentSubsetReattachBypassesDurableBusy covering restored attachment fence 5, blocked durable persistence, subset reattach success, wrong principal rejection before busy, and broader cap rejection. Validation: cd services/subagents && PATH=/home/shyylol/.local/opt/go/bin:/home/shyylol/.pi/agent/bin:/home/shyylol/.local/opt/nvm/versions/node/v24.19.0/bin:/home/shyylol/.local/bin:/usr/local/bin:/usr/bin:/bin go test -race ./internal/actors ./internal/service; git diff --check. No commit/push/deploy.

Implemented regular-terminal delivery backend slice. AgentActor now selects hosted vs regular backend from durable attachment state: hosted BridgeReady uses existing hosted bridge delivery; an attached regular terminal principal can accept ActorTask into the durable bridge delivery queue with backend=regular. Regular client sessions self-attach to their stable terminal actor when it already exists, service pushes regular backend deliveries over the existing actor-client websocket, actor-client renders one communication card and ACKs over its regular fence, and regular ACKs commit through the existing dedupe/cursor/completion path. Added TestActorTaskDeliversToRegularTerminalAttachment for hosted source -> inactive regular terminal, durable queued/polled, ACK, and source completion routing. Validation: services/subagents ./tools/codegen.sh verify; go test -race ./...; go vet ./...; npm test; NODE_OPTIONS='--import ./services/subagents/node_modules/tsx/dist/loader.mjs' node --test tests/actor-client/*.mjs; git diff --check. No commit/push/deploy. actor-client TypeScript changed; PM /reload required for live E2E.

PM review blocker fixes: moved authoritative regular push to actorReplyBroker TargetTaskCommitted (hosted and regular pushers both fire post-target-commit; source admission no longer calls regular pusher). Added a real service socket regression proving no BridgePushFrame before commit and exactly one regular delivery frame after commit. Replaced immediate fake regular ACK with RegularDeliveryCoordinator: durable custom-entry injected/acked markers, incoming note/request cards, model-visible pi.sendMessage followUp with triggerTurn, tell ACK only after injection, prompt ACK only after agent_end + agent_settled with the bounded actual assistant answer, deadline/injection/shutdown terminal failure ACKs, ACK retry retention, and reload/reconnect marker restoration without duplicate injection/ACK. Added actor-client tell/ask/expiry/replay tests and actor Ask regression proving the actual model answer returns to source ActorRef. Full relevant gates passed: service codegen verify, go test -race ./..., go vet ./..., npm test; combined hosted/actor-client 59 tests; nvim capability tests; Stylua via managed Mason binary; git diff --check. tmux-subagents: 93/97 passed, 4 environment-only failures because tmux is absent (spawn tmux ENOENT). chezmoi dry-run likewise blocked because template command -v tmux fails. No commit/push/deploy. actor-client TypeScript changed: PM /reload required.

Terminal actor-tell reload collision root cause: hosted bridge adopted daemon high-water, but regular actor-client OPEN did not. Added authoritative actor_message_high_water to ClientSessionResponse, queried from the stable terminal AgentActor before session issuance, and adopted it in actor-client before opening the regular message path. Regression seeds retained sequence 10 and proves OPEN returns 10 and first post-reload allocation is 11.
<!-- SECTION:NOTES:END -->
