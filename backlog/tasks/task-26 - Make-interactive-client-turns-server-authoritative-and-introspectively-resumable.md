---
id: TASK-26
title: >-
  Make interactive client turns server-authoritative and introspectively
  resumable
status: In Progress
assignee:
  - '@pi'
created_date: '2026-09-02 17:12'
updated_date: '2026-09-02 17:25'
labels: []
dependencies: []
references:
  - docs/architecture/subagents/0006-durable-agent-threads-and-introspection.md
  - services/subagents/internal/actors/agent.go
  - home/dot_pi/private_agent/extensions/actor-client/index.ts
ordinal: 42000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Represent the interactive Pi client as a durable server-authoritative AgentActor execution profile. User input, actor delivery, self-continuation, settlement, and completion live in its mailbox while the local Pi process remains a fenced model/tool executor. Reincarnations catch up unfinished work, and isolated introspection automatically resumes future-action promises instead of requiring another user turn.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Interactive user input is durably admitted to the Client AgentActor mailbox before model execution and is deduplicated by server-issued turn identity
- [ ] #2 Exactly one fenced client incarnation may execute and settle model-bearing work while other connections remain observers
- [ ] #3 Every settled interactive turn runs isolated introspection and a future-action promise without terminal evidence durably enqueues a bounded self-continuation
- [ ] #4 Client reincarnation adopts mailbox and settlement high-water, replays unfinished turns exactly once, and resumes the active thread without polling
- [ ] #5 Tell, Ask, user turn, self-continuation, waiting, blocked, completion, and presentation ACK retain distinct typed semantics
- [ ] #6 Raw reasoning and credentials never enter durable state; only bounded owner-private input, result, checkpoint, tool receipts, and protocol identity are retained
- [ ] #7 Race-safe protocol, daemon, actor-client, restart, duplicate, fencing, introspection, and live E2E tests prove user → client mailbox → local Pi → introspection → automatic continuation → terminal response
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Run two read-only architecture/protocol/security council rounds and freeze the authority, mailbox, fencing, settlement, introspection, privacy, and recovery contract.\n2. Map the approved contract onto the existing AgentActor, protocol, service, actor-client, native Pi session identity, and durable-state seams; split implementation only where independent reviewable slices are required.\n3. Implement one-writer-at-a-time server and actor-client changes with generated boundaries and durable-before-effects ordering.\n4. Run independent architecture/security and correctness reviews; route findings back to the retained implementer and repeat review after correction.\n5. Run race, vet, codegen, protocol, extension, capability, restart/reincarnation, and live automatic-continuation E2E gates; finalize only with durable mailbox evidence.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Dogfood orchestration halted by operator after all six panes entered warning. All six exact team actors were stopped. Daemon evidence: supervisor received repeated stale/duplicate TaskCreditGranted messages classified invalid_expired_or_unknown for four result-bearing asks; frontend and QA then entered persistent BridgeDeliveryAck rejection loops with identity mismatch class run-counter (sequence 8), and supervisor sequence 1 also rejected at stop. The hosted actor_ask surface returns admission/pending rather than suspending the worker for ActorTaskCompleted, so the supervisor advanced and emitted additional round traffic before durable results were injected back into its model thread. Dense multi-actor orchestration therefore is not sound: completion-to-hosted-source mailbox wake and multi-prompt settlement/run correlation must be fixed before restarting TASK-26 implementation.

Retry playbook after communication fixes:\n\nTeam topology (recreate only after hosted-source completion wake, same-thread continuation, run-counter settlement, and stale-credit idempotency pass focused gates):\n- client_actor_supervisor — independent implementation supervisor — /home/shyylol/dev/ui-dashboard-manager\n- client_actor_architect — distributed actor architect — /home/shyylol/dev/lazyvim-thread-arch\n- client_actor_security — protocol security reviewer — /home/shyylol/dev/lazyvim-task-credit-review\n- client_actor_runtime — daemon runtime implementer — /home/shyylol/dev/lazyvim-research-runtime\n- client_actor_frontend — Pi client implementer — /home/shyylol/dev/lazyvim-research-frontend\n- client_actor_qa — independent QA reviewer — /home/shyylol/dev/lazyvim-ui-qa\n\nCommunication-only supervisor assignment:\n1. Dogfood only owned AgentActor tools. Use actor_ask for every result-bearing assignment, critique, review, and correction; actor_tell only for non-result notifications. Never use pi-subagents, pane injection, files as a messaging substitute, or actor_stop for phase transitions.\n2. Round 1: obtain terminal Ask results from all five participants for independent implementation-detail proposals covering server-authoritative interactive mailbox, durable input admission, fenced local Pi execution, settlement, isolated introspection, self-continuation, privacy, reincarnation recovery, and tests. Do not advance on admission/pending receipts.\n3. Round 2: after all five ActorTaskCompleted results are durably injected into the supervisor thread, send each participant a bounded synthesis and obtain terminal critiques of invariants, conflicts, cutover, Pi API feasibility, security, and testability. Do not implement before all round-2 completions settle.\n4. Freeze decisions and plan in TASK-26. Assign non-overlapping runtime/frontend slices with one writer per worktree and typed Ask coordination for generated boundaries.\n5. Route architecture/security reviews to architect and security, correctness/restart/E2E review to QA, and every blocker back to the retained owning implementer through actor_ask. Repeat independent review after fixes.\n6. Supervisor integrates only reviewed commits on a clean origin/main-based branch, runs relevant codegen/race/vet/protocol/extension/capability/restart gates, and returns one final ActorTaskCompleted on the original client Ask. Intermediate acknowledgements, promises, or working-status messages cannot complete the supervisor thread.\n7. Final result must include frozen decisions, both-round participant matrix, reviewed and integration commit hashes, exact tests/evidence, residual risks, deployment/restart instructions, and communication proof.\n\nObserver setup: create a dedicated client-actor-team tmux window with six cooperative foreground attachments to hosted sessions, tiled panes titled Supervisor, Architect, Security, Runtime, Frontend, and QA; enable pane-border-status top. Never use send-keys or respawn-pane.\n\nAbort conditions for retry: any participant warning/degraded state; repeated credit-grant rejection; ACK identity mismatch; round advancement before terminal completions; missing same-thread completion wake; optimistic tool text treated as a result; or durable receipts not converging.
<!-- SECTION:NOTES:END -->
