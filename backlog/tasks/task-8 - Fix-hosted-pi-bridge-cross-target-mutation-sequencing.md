---
id: TASK-8
title: Fix hosted-pi-bridge cross-target mutation sequencing
status: Done
assignee:
  - '@dev-actor-client'
created_date: '2026-08-31 22:42'
updated_date: '2026-09-02 02:59'
labels: []
dependencies: []
type: bug
ordinal: 8000
---

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Hosted bridge allocates one dense actor-message sequence across targets while retaining target-fence-specific control scopes
- [x] #2 Fresh and reconnecting hosted bridge processes adopt daemon-authoritative high-water before allocation and preserve immutable replay
- [x] #3 Focused hosted bridge mutation tests and full relevant repository gates pass
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Duplicate the actor-client ClientMutationSequencer semantics into an extension-local hosted-pi-bridge/mutations.ts (no cross-extension imports). 2. Scope message() to ONE namespace per bridge binding across all actor-message targets (daemon routes hosted actorMessageRequest through SendActorTask on the hosted source agent whose namespace is global per source agent); keep control() per target fence (daemon scopes control per session#control+fence). 3. Retire all session scopes at session shutdown after fence detach; reconnects keep the namespace and reconcile by immutable replay. 4. Mirror the client Node tests. 5. Full gates.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented: new home/dot_pi/private_agent/extensions/hosted-pi-bridge/mutations.ts (ClientMutationSequencer/ClientMutationSequenceError/isClientSequenceFailure with retain+reconcile immutable replay, bounded retries with cooldown, loud sequence-collision failure, retireScopes). index.ts message() now uses bridgeMessageScopeKey(binding) — one namespace across targets; control() uses bridgeControlScopeKey(binding,fence) per target fence; session_shutdown detaches fences then retires all scopes under bridgeSessionToken(binding) (also removes a latent requiredBinding throw in the detach loop); helpers added near loadBinding. Old ExactMutationSequencer remains exported from handlers.ts untouched with its existing tests (now unused by index.ts; removal rides with the daemon-side scope fix). package.json test script gains tests/hosted-pi-bridge/mutations.test.mjs. Tests: 8 new mirrored cases — second-peer advances 2,3; concurrent multi-peer queue with serialized allocation; reconnect replays immutable request then resumes high-water+1; loud collision no-retry keeping high-water; control per-target independence vs shared message namespace; bounded retries with cooldown; shutdown retirement covers message+control and restarts at 1; rejection-family classification. Gates: bridge suite 34/34; actor-client 16/15/1 (single failure remains the pre-existing ACTOR_ASK_COMPLETION_TIMEOUT contract mismatch awaiting PM decision); tmux-subagents 93/97 with all 4 failures environmental (spawn tmux ENOENT, host lacks tmux binary; stylua + chezmoi dry-run blocked by the same missing binary); capabilities PASS; services/subagents codegen verify + go vet + go test -race ./... + npm test 6/6 all PASS; git diff --check OK. No commit/push/deploy. KNOWN LIMIT (flagged to PM): the hosted source agent namespace is durable across bridge process restarts, so a fresh bridge process restarting at sequence 1 can hit a loud collision if the daemon still retains prior sequences — there is no protocol surface to query the high-water; the daemon-side ADR-0005 scope fix is the durable resolution.

Final verification supersedes the original missing-high-water limitation: daemon handshake adoption landed under TASK-15; hosted bridge suite passed 36/36, service codegen/race/vet/protocol gates passed, and multi-target owned-agent reports completed without collision.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Implemented hosted bridge cross-target message sequencing, per-fence control scopes, immutable replay, bounded retries, retirement, and authoritative high-water adoption. Verified by 36/36 hosted bridge tests and owned-agent live completion traffic.
<!-- SECTION:FINAL_SUMMARY:END -->
