---
id: TASK-8
title: Fix hosted-pi-bridge cross-target mutation sequencing
status: In Progress
assignee:
  - '@dev-actor-client'
created_date: '2026-08-31 22:42'
updated_date: '2026-08-31 22:45'
labels: []
dependencies: []
type: bug
ordinal: 8000
---

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Duplicate the actor-client ClientMutationSequencer semantics into an extension-local hosted-pi-bridge/mutations.ts (no cross-extension imports). 2. Scope message() to ONE namespace per bridge binding across all actor-message targets (daemon routes hosted actorMessageRequest through SendActorTask on the hosted source agent whose namespace is global per source agent); keep control() per target fence (daemon scopes control per session#control+fence). 3. Retire all session scopes at session shutdown after fence detach; reconnects keep the namespace and reconcile by immutable replay. 4. Mirror the client Node tests. 5. Full gates.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented: new home/dot_pi/private_agent/extensions/hosted-pi-bridge/mutations.ts (ClientMutationSequencer/ClientMutationSequenceError/isClientSequenceFailure with retain+reconcile immutable replay, bounded retries with cooldown, loud sequence-collision failure, retireScopes). index.ts message() now uses bridgeMessageScopeKey(binding) — one namespace across targets; control() uses bridgeControlScopeKey(binding,fence) per target fence; session_shutdown detaches fences then retires all scopes under bridgeSessionToken(binding) (also removes a latent requiredBinding throw in the detach loop); helpers added near loadBinding. Old ExactMutationSequencer remains exported from handlers.ts untouched with its existing tests (now unused by index.ts; removal rides with the daemon-side scope fix). package.json test script gains tests/hosted-pi-bridge/mutations.test.mjs. Tests: 8 new mirrored cases — second-peer advances 2,3; concurrent multi-peer queue with serialized allocation; reconnect replays immutable request then resumes high-water+1; loud collision no-retry keeping high-water; control per-target independence vs shared message namespace; bounded retries with cooldown; shutdown retirement covers message+control and restarts at 1; rejection-family classification. Gates: bridge suite 34/34; actor-client 16/15/1 (single failure remains the pre-existing ACTOR_ASK_COMPLETION_TIMEOUT contract mismatch awaiting PM decision); tmux-subagents 93/97 with all 4 failures environmental (spawn tmux ENOENT, host lacks tmux binary; stylua + chezmoi dry-run blocked by the same missing binary); capabilities PASS; services/subagents codegen verify + go vet + go test -race ./... + npm test 6/6 all PASS; git diff --check OK. No commit/push/deploy. KNOWN LIMIT (flagged to PM): the hosted source agent namespace is durable across bridge process restarts, so a fresh bridge process restarting at sequence 1 can hit a loud collision if the daemon still retains prior sequences — there is no protocol surface to query the high-water; the daemon-side ADR-0005 scope fix is the durable resolution.
<!-- SECTION:NOTES:END -->
