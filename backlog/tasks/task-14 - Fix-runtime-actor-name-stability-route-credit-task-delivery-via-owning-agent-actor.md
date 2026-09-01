---
id: TASK-14
title: >-
  Fix runtime actor name stability: route credit/task/delivery via owning agent
  actor
status: Done
assignee:
  - '@pi'
created_date: '2026-09-01 22:23'
updated_date: '2026-09-01 22:51'
labels: []
dependencies: []
modified_files:
  - services/subagents/internal/actors/agent.go
  - services/subagents/internal/actors/agent_registry.go
  - services/subagents/internal/actors/actor_task_redrive_test.go
priority: high
type: bug
ordinal: 14000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
PM TASK-12d (same name-stability class as agent names). f985301 deployed - expired credits discard properly, items cycle to pending_credit. NEW blocker: credit REQUESTS never get grants. Journal shows 'actor=hosted-pi-runtime-<hash> not found' repeating (4 runtime hashes). hostedRuntimeActorName (agent_registry.go:590) digests agentID+runtimeID+piSessionName so the name rotates every incarnation; any durable/stale ref or resolution recomputed from an old recorded spec points at a dead actor after any runtime bounce (same class as pre-stable-name agent bug). Fix: route credit/task/delivery messages to the owning agent actor (stable agent-<sha8(agentID)>) and forward to live runtime child internally, or make runtime names deterministic per runtime_id resolved fresh through parent. Audit every resolution site for hosted-pi-runtime-* usage from durable state. Regression: bounce incarnation mid-queue -> pending credit request grants under new incarnation without manual intervention. Also check researchers cursor=0 queued=0 while worker cursor=6 (deliveries never arrive - likely same routing).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Durable actor refs with a logical AgentID resolve directly to the owning stable agent-<sha8(agentID)> actor locally and remotely, never to a stale hosted-pi-runtime-* child
- [x] #2 Credit grants/tasks/completions accept only the resolved owning agent actor identity after an incarnation/re-registration bounce; unrelated actors remain rejected
- [x] #3 Regression bounces/replaces a target incarnation while a pending outbox item retains the old runtime ref and proves credit grant -> ActorTask -> target bridge delivery without manual intervention
- [x] #4 Audit confirms hosted runtime names are lifecycle-internal only; focused and full services/subagents gates plus git diff --check pass
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Audit all runtime-name and durable ActorRef construction/resolution sites and reproduce the stale runtime ref credit failure. 2. Canonicalize logical AgentID durable routing and sender validation to the owning stable agent actor for local and remote refs; keep anonymous refs exact. 3. Add bounce regression covering pending credit through the replacement owner and target delivery, plus negative identity coverage. 4. Run focused tests, full services/subagents gates, diff check, document evidence, and report to PM without commit/push/deploy.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Reproduced the live class before implementation: the new runtime-bounce regression timed out with a pending_credit item whose TargetRef named a stopped hosted-pi-runtime child. Root cause was two-part: lookup fell back to the stable owner, but TaskCreditGranted/ActorTaskAccepted sender validation still compared the grant against the stale child path; direct admission could also Tell a retained runtime PID. Implemented stable-owner-first local/remote lookup, runtime-child fallback refusal, owner-name sender authentication on the recorded node, and a direct-send guard. Focused actors package tests pass, including stale-runtime bounce -> credit -> task -> replacement bridge delivery.

Validation evidence: regression failed before the fix, then passed under -race and 20 consecutive runs; TestActorTaskGrantAndAcceptanceRequireReservedTargetOrigin and TestActorRefPathFieldsMustMatchReservedTargetRef passed x5; TestRemoteHostedOrdinaryServicePath passed. Full service gate passed: npm ci, codegen verify, go test -race ./..., go vet ./..., npm test. Repository checks: capabilities test passed; tmux-subagents npm ci passed; 93/97 Node tests passed with the only 4 failures all spawn tmux ENOENT; managed Mason stylua check passed; git diff --check passed. Scratch chezmoi dry-run is likewise unavailable because command -v tmux exits 127. No commit, push, or deploy performed.

PM reporting blocker: actor-tell to client:01a04959-c544-7a2a-8533-1031c0b36c56 was attempted twice (detailed and concise) and both failed. Exact error: client mutation sequence failed for scope hosted-session-_OzGuFjwtfBu-xXWllVHKLdJspVL6-YfIxZO5cMQgrQ<NUL>hosted-generation-_OzGuFjwtfBu-xXWllVHKLdJspVL6-YfIxZO5cMQgrQ<NUL>hosted:task_credit_impl_worker<NUL>task_credit_impl_worker<NUL>messages at sequence 1: source mutation sequence collision. Evidence remains in this task and the final user response.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Routed every logical durable ActorRef through the stable owning AgentActor instead of an incarnation-scoped hosted runtime child, authenticated returned credit/acceptance against that stable owner on the recorded node, and blocked direct credit Tells to retained runtime PIDs. Added a regression that starts with a pending outbox ref to a stopped old runtime, binds incarnation 2 to the retained owner, and proves credit grant -> ActorTask -> bridge delivery. Full services/subagents gates and focused local/remote/security tests pass; repository-only tmux checks remain unavailable because this host has no tmux.
<!-- SECTION:FINAL_SUMMARY:END -->
