---
id: TASK-1
title: Actor-client XState v5 projections and project crews
status: In Progress
assignee:
  - '@pi'
created_date: '2026-08-31 21:41'
updated_date: '2026-09-02 04:47'
labels: []
dependencies: []
priority: high
type: feature
ordinal: 1000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deliver the workstation extension complete actor-client UX on the owned distributed-agent framework. XState v5 owns disposable frontend projections; daemon AgentActor state remains authoritative. The initiative includes production-wired responsive conversation cards, truthful topic-backed dynamic activity metadata, declarative project crew bootstrap, and live E2E coverage of the approved Actor UX design system.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Production actor-client rendering uses bounded XState snapshots for the complete approved conversation-card, status, tool, replay, and responsive-layout contract
- [ ] #2 AgentActor publishes revision-fenced dynamic activity metadata that drives status and exactly owned runtime UI without fixed domain phases, role inference, liveness inference, or polling
- [ ] #3 A project-root `.crew.toml`, automatic Pi startup, and `/crew spawn` idempotently bootstrap and retain the configured AgentActors without WorkflowActor orchestration or PM UI dependence
- [ ] #4 The Actor UX design system live acceptance matrix passes and the canonical roadmap reflects the shipped state and next cutover work
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Complete the production renderer/widget wiring and live conversation acceptance matrix.
2. Add dynamic activity-metadata publication and frontend/runtime topic projection.
3. Implement project-root `.crew.toml`, idempotent registry reconciliation, automatic Pi startup, and `/crew spawn`.
4. Dogfood the six-agent repository crew, review, deploy, reload, record E2E evidence, and advance the authority-cutover roadmap.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Product scope changed by operator decision: remove WorkflowActor orchestration and durable decision UX from this initiative. Declarative crew bootstrap is the replacement; AgentActors and normal task/message protocols remain authoritative.
<!-- SECTION:NOTES:END -->
