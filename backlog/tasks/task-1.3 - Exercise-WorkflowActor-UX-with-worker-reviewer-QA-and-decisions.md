---
id: TASK-1.3
title: Declarative project crews and idempotent agent bootstrap
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 02:56'
updated_date: '2026-09-02 04:46'
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
Replace the planned WorkflowActor orchestration and durable-decision feature with a declarative project crew. A project-root `.crew.toml` defines long-lived AgentActors and their default hosted Pi system prompts. Starting Pi in the project and `/crew spawn` both invoke the same authenticated, idempotent registry reconciliation. The crew manifest bootstraps actors only; it does not become workflow authority, infer phases, automate handoffs, or stop retained participants.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Current-directory project-root discovery loads an optional `.crew.toml` deterministically; absence is a no-op and invalid configuration fails visibly without partial ambiguous state
- [ ] #2 The manifest defines stable agent identity, display metadata, role, and a bounded per-agent `prompt` loaded as the hosted Pi system prompt, without making display metadata authoritative for routing
- [ ] #3 `/crew spawn` accepts TOML contents or uses the discovered root manifest, and Pi startup uses the identical authenticated registry path automatically
- [ ] #4 Repeated, concurrent, reconnect, and restart reconciliation is idempotent: existing retained AgentActors/runtimes are reused, only missing entries are created, and identity/config conflicts fail closed without duplicate writers
- [ ] #5 This repository dogfoods `.crew.toml` with six agents: architecture, UI/UX, actor-model plus GoAkt v4 specialist, developer, reviewer, and QA
- [ ] #6 Automated and live E2E evidence proves discovery, prompt loading, partial-retry recovery, concurrent idempotency, retained actors, redaction, and no WorkflowActor dependency
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Product decision: WorkflowActor orchestration and durable decision cards are removed from this roadmap slice. `.crew.toml` is declarative bootstrap configuration only. Ordinary coordination remains ActorTask/ActorTaskCompleted and actor Tell/Ask between retained AgentActors.
<!-- SECTION:NOTES:END -->
