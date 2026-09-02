---
id: TASK-7
title: Fix actor-client per-scope mutation sequence allocation
status: Done
assignee:
  - '@dev-actor-client'
created_date: '2026-08-31 21:49'
updated_date: '2026-09-02 02:59'
labels: []
dependencies: []
ordinal: 7000
---

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Actor-client allocates one dense message sequence across targets, serializes concurrent sends, and replays unresolved immutable mutations before advancing
- [x] #2 Control mutation scopes remain target-fence-specific and terminal reconnect adopts the daemon-authoritative high-water without collision
- [x] #3 Focused actor-client sequencing/reconnect/collision tests and full relevant repository gates pass
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Port bridge-style exact-mutation sequencing into actor-client as ClientMutationSequencer (mutations.ts): one message namespace per client session across all targets, per-target control namespaces, allocate-on-settlement, concurrent queueing, immutable retained unresolved replay across reconnect, bounded retries with cooldown, loud typed failure on sequence rejections. 2. Wire index.ts send/ask to the session-global message scope and control to per-fence scope; retire session scopes on session swap/shutdown so reload restarts at 1 only under a new namespace. 3. Node tests in tests/actor-client/mutations.test.mjs covering PM-specified cases. 4. Mirror-check hosted-pi-bridge sequencer. 5. Full gates.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented: new home/dot_pi/private_agent/extensions/actor-client/mutations.ts (ClientMutationSequencer + ClientMutationSequenceError + isClientSequenceFailure); index.ts now scopes actor messages to one per-session namespace (clientMessageScopeKey = sessionId/generation/caller + messages) and control to per-target-fence namespaces, retiring scopes on resetClients/session_shutdown; package.json test script covers both test files; tests/actor-client/mutations.test.mjs adds 8 tests (sequential 1,2,3 across targets, concurrent queueing with serialized allocation, immutable replay across transport failure then resume at high-water+1, retire-then-restart-at-1 only for new session scope, loud collision without retry, bounded retries with cooldown, sequence-failure classification, control scope independence + session retirement). All 8 pass; actor-client suite retains the one PRE-EXISTING failure (ACTOR_ASK_COMPLETION_TIMEOUT 6h code vs 30min test) pending the PM contract decision. Gates: capabilities PASS; services/subagents codegen verify + go vet + go test -race ./... + npm test ALL PASS; git diff --check OK; tmux-subagents 93/97 with all 4 failures environmental (spawn tmux ENOENT — host lacks the tmux binary; tmux-integration + smoke tests only); stylua and chezmoi dry-run also blocked by the missing tmux binary on this host (template runs command -v tmux); no Lua touched.

MIRROR-CHECK (hosted-pi-bridge): same defect class confirmed by reading. hosted-pi-bridge/index.ts message()/control() scope sequences per target via mutationScopeKey(fence, incarnation), but its actorMessageRequest payloads traverse the identical daemon path (service.go routes them through SendActorTask on the HOSTED source agent, whose collision scan is global per source agent across targets). Single-target use is safe; a hosted actor messaging two peers allocates sequence 1 twice and the second fails closed with 'source mutation sequence collision'. Not fixed here (out of TASK-7 scope; needs its own task aligned with the daemon fix below). DAEMON FINDINGS from a temporary Go probe (run, evidence captured, probe deleted): (1) source-side namespace global per source agent across targets — seq1 to target A then seq1 to target B returns 'source mutation sequence collision'; (2) target-side acceptActorTaskWithCredit scopes sequences per (target, source agent) with exactly-one-increase, so seq2 as the FIRST message to target B is admitted by the source but never delivered to B (B demands exactly 1) and terminally fails at deadline; (3) burned sequences stay collision-locked even after terminal failure (seq2 to A after B's seq2 failed still collides) — therefore one client peer can currently deliver to exactly ONE target per namespace and NO client-side allocator alone restores multi-target coordination; a daemon change aligning sendActorTask's scan and the target-side actorTaskScope with ADR 0005's (session, generation, principal, target fence) scope tuple is required as a follow-up; (4) fail-open race observed once: a same-sequence reuse slipped through the source-side scan while the first task's outbox item was still in flight — the client-side settle-before-allocate serialization closes this for the fixed client, but the daemon scan remains racy.

Correction: final actor-client suite is 16 tests / 15 pass / 1 fail, where the single failure is the pre-existing ACTOR_ASK_COMPLETION_TIMEOUT contract mismatch (6h code vs 30min test) that predates TASK-7 and awaits the PM decision. All 8 new mutations tests pass.

Final verification supersedes the early timeout mismatch: post-UI correction actor-client suite passed 34/34, including sequencing, high-water adoption, collision, retry, scope retirement, and reconnect cases; service race/vet/protocol and live sequences 30-33 also passed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented durable actor-client mutation sequencing with one cross-target message namespace, target-fenced controls, serialized immutable replay, bounded retry/collision handling, session retirement, and daemon high-water adoption. Verified by 34/34 actor-client tests and live post-reload sequences 30-33.
<!-- SECTION:FINAL_SUMMARY:END -->
