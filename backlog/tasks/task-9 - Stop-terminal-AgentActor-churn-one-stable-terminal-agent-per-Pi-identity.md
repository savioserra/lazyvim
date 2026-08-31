---
id: TASK-9
title: 'Stop terminal AgentActor churn: one stable terminal agent per Pi identity'
status: To Do
assignee:
  - '@dev-actor-client'
created_date: '2026-08-31 22:48'
updated_date: '2026-08-31 22:58'
labels: []
dependencies: []
type: bug
ordinal: 9000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Every client session OPEN mints a fresh ephemeral caller identity, and ensureTerminalAgent registers a NEW terminal AgentActor per identity. Reconnects and daemon restarts therefore orphan prior terminal agents whose retained ReceivedTaskCompletions mailboxes never drain, so correlated ask completions never reach the attached terminal. Fix per ADR 0005: one stable terminal AgentActor per Pi identity surviving reconnects and daemon restarts; persist/reuse its stable ID locally, reattach instead of re-create, drain retained completions after reattach, and make ensureTerminalAgent idempotent on that identity.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Reconnect reattaches the same terminal AgentActor and drains retained completions
- [ ] #2 Daemon restart followed by reconnect reattaches the same terminal AgentActor
- [ ] #3 Concurrent connections from one Pi identity do not mint duplicate terminal agents
- [ ] #4 Orphaned terminal agents are no longer created by ordinary reconnects
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Proto: add terminal_identity to ClientSessionRequest; regenerate via tools/codegen.sh (refreshes Go + both extension subagents_pb.ts). 2. Daemon: OPEN accepts a validated [A-Za-z0-9_-]{1,48} terminal_identity and mints Caller=client:<identity> (empty keeps legacy random mint); ensureTerminalAgent + durable reconcile already give idempotent reattach and restart survival; reply-session registration already drains the principal agent per request. 3. actor-client: derive stable identity from the Pi session identity, send it on OPEN; re-key the TASK-7 message scope to the stable caller (continues high-water across session re-OPENs), keep control per session+fence, retire scopes only at session_shutdown, adopt drained-completion sequence floors (adoptHighWater). 4. Go service tests: reconnect reattaches+drains, daemon restart+reconnect reattaches, concurrent OPENs mint one agent, legacy OPEN unchanged. 5. Extension tests for scope re-keying/adopt/retirement. 6. Full gates; stage with TASK-7/8 and report combined.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Root cause confirmed at the mint site: every ClientSessionRequest OPERATION_OPEN mints Caller='client:'+random (service.go clientSessionResponse), and each ActorMessageRequest routes through ensureTerminalAgent(caller) — so every reconnect/daemon-restart re-OPEN registered a NEW terminal AgentActor while prior agents durably retained ReceivedTaskCompletions that no session principal could ever drain again (the reply-drain in flushActorReplies authorizes by the session principal's agent). Fix: (1) proto ClientSessionRequest.terminal_identity (validated [A-Za-z0-9_-]{1,48}, empty keeps legacy ephemeral mint, malformed fails closed INVALID_REQUEST); Caller becomes client:<terminal_identity> so all sessions from one terminal share ONE durable terminal AgentActor. ensureTerminalAgent was already idempotent per identity and reconcileDurableRecord already re-materializes terminal records at daemon start, and registerActorReplySession already drains the principal agent per authenticated envelope — stability of the principal is what activates all three. Codegen regenerated (Go + shared TS + both extension copies). (2) actor-client extension: OPEN now sends terminalIdentity derived from the Pi session identity (terminalClientIdentity: pass-through when bounded/clean, sha256-40 otherwise, empty when unavailable); TASK-7 message scope re-keyed to the stable caller (clientMessageScopeKey(caller)) so session re-OPENs continue the namespace instead of restarting at 1 and colliding; control scopes stay per session+target fence under the caller prefix; resetClients no longer retires scopes (namespace survives re-OPENs); session_shutdown retires by caller prefix; drained actorMessageReplyFrame pushes floor the allocator via new adoptHighWater (never lowers, safe during replay) closing the reload-restart-at-1 window. Tests: 5 new Go service tests (reattach+drain across reopens with a seeded retained completion delivered to the reattached session's reply channel; durable restart reattach with exactly one record/agent; concurrent opens + concurrent ensureTerminalAgent mint exactly one agent; malformed identities fail closed; legacy empty-identity open unchanged) — all pass under -race; 2 new extension tests (adoptHighWater floor/never-rewind/resume-above-floor; message scope stable across session churn, control scopes per session+fence, terminalClientIdentity sanitization incl. exact sha256 vector). Gates: codegen verify OK, go vet OK, go test -race ./... PASS, services npm test 6/6, bridge 34/34, actor-client 18 tests/17 pass/1 pre-existing timeout-contract failure (still awaiting PM decision), capabilities PASS, git diff --check OK, tmux-subagents 93/97 environmental (tmux binary absent on host). Staged with TASK-7/TASK-8; no commit/push/deploy.
<!-- SECTION:NOTES:END -->
