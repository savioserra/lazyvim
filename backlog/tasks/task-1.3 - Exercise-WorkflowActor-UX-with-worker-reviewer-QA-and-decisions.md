---
id: TASK-1.3
title: Declarative project crews and idempotent agent bootstrap
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 02:56'
updated_date: '2026-09-02 05:24'
labels: []
dependencies: []
references:
  - docs/architecture/subagents/ROADMAP.md
  - docs/architecture/subagents/ACTOR-UX-DESIGN-SYSTEM.md
parent_task_id: TASK-1
priority: high
type: feature
ordinal: 21000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Replace the planned WorkflowActor orchestration and durable-decision feature with a declarative project crew. A project-root `.crew.toml` defines long-lived participant AgentActors, default hosted Pi system prompts, and an optional prompt-driven `crew.supervisor` AgentActor. Starting Pi and `/crew spawn` invoke the same authenticated, idempotent registry reconciliation. The manifest is not workflow state or authority; the supervisor observes only its crew and coordinates through normal typed actor messages without pane automation or ordinary actor teardown.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Current-directory project-root discovery loads an optional `.crew.toml` deterministically; absence is a no-op and invalid configuration fails visibly without partial ambiguous state
- [ ] #2 The manifest defines stable participant identity, display metadata, role, bounded per-agent `prompt`, and one optional `crew.supervisor` identity/prompt without making metadata authoritative for routing
- [ ] #3 `/crew spawn` accepts TOML contents or uses the discovered root manifest, and Pi startup uses the identical authenticated registry path automatically
- [ ] #4 Repeated, concurrent, reconnect, and restart reconciliation is idempotent: existing retained participant/supervisor AgentActors and runtimes are reused, only missing entries are created, and conflicts fail closed without duplicate writers
- [ ] #5 This repository dogfoods `.crew.toml` with six participant agents plus one supervisor: architecture, UI/UX, actor-model plus GoAkt v4 specialist, developer, reviewer, QA, and prompt-driven coordination
- [ ] #6 The supervisor watches authenticated topic projections for its declared crew and coordinates only through ActorTask/ActorTaskCompleted and Tell/Ask, with no WorkflowActor, polling, pane injection, or ordinary stop/abort/shutdown authority
- [ ] #7 Automated and live E2E evidence proves discovery, prompt loading, partial-retry recovery, concurrent idempotency, supervised coordination, retained actors, redaction, and one-writer enforcement
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Product decision: WorkflowActor orchestration and durable decision cards are removed from this roadmap slice. `.crew.toml` is declarative bootstrap configuration only. Ordinary coordination remains ActorTask/ActorTaskCompleted and actor Tell/Ask between retained AgentActors.

Added product requirement: optional `crew.supervisor` is a retained normal AgentActor configured with a specialized prompt and crew-scoped observation/coordination capabilities. It is not a new transport actor class and does not restore WorkflowActor authority.
<!-- SECTION:NOTES:END -->
