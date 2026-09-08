---
id: TASK-21
title: Prevent ready hosted runtimes regressing to starting
status: In Progress
assignee:
  - '@pi'
created_date: '2026-09-02 05:34'
updated_date: '2026-09-02 13:35'
labels: []
dependencies: []
references:
  - services/subagents/internal/actors/hosted_pi_runtime.go
  - services/subagents/internal/actors/agent.go
  - services/subagents/internal/actors/agent_registry.go
priority: high
type: bug
ordinal: 29000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Fresh deployment and exact recreation of five hosted agents produced durable/runtime projections with `BridgeReady=true` but lifecycle state `starting`. Actor health therefore rendered `available` instead of `ready`. Startup and bridge-readiness messages can interleave within one incarnation, and same-incarnation runtime projection validation currently accepts regressions. Preserve independent lifecycle/readiness facts while ensuring the latest authoritative startup state converges deterministically.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A hosted runtime with a live validated process and authoritative bridge readiness converges to lifecycle ready regardless of startup/readiness message ordering
- [ ] #2 A stale same-incarnation starting projection cannot overwrite a newer ready, degraded, stopping, or stopped projection
- [ ] #3 Lifecycle fencing does not infer readiness from liveness, tmux, elapsed time, or output; only typed runtime and bridge authority may advance state
- [ ] #4 Durable registration, AgentActor status, registry/public roster, actor-client status, and hosted runtime child agree on lifecycle and bridge readiness after convergence
- [ ] #5 Race tests permute startup/readiness/state-change ordering and repeated fresh recreation/restart never leaves BridgeReady=true with lifecycle starting
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
QA post-fix matrix: actor-local early-readiness merge passes; still require same-incarnation stale-starting protection at AgentActor/registry/service/roster, ordering permutation tests, and fresh-runtime convergence proof.

Reviewer confirms same-incarnation runtimeProjectionAdvances accepts every projection in agent_registry and AgentActor, allowing stale starting to overwrite ready/BridgeReady. Require monotonic projection advancement with bridge readiness independent.

Implemented same-incarnation lifecycle lattice: ready cannot regress to starting, degraded cannot revive in place, stopped is terminal, and recovery must pass degraded -> next-incarnation starting. Bridge loss now clears BridgeReady without changing a live process back to starting; AgentActor preserves a newer fenced bridge-ready declaration over delayed ready snapshots. Added transition-table and bridge disconnect/reconnect tests; actor race suite passes.

Corrected shutdown/quiescence interaction: direct authoritative Ready=false now clears the AgentActor bridge declaration before forwarding, so stale-ready preservation cannot defeat service quiescence. Remote integration cleanup proof passes.
<!-- SECTION:NOTES:END -->
