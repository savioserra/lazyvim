---
id: TASK-1.3.4
title: Dogfood the six-agent repository crew
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 04:46'
updated_date: '2026-09-02 04:46'
labels: []
dependencies:
  - TASK-1.3.3
references:
  - .crew.toml
  - docs/architecture/subagents/ROADMAP.md
  - docs/subagents.md
  - docs/tools.md
parent_task_id: TASK-1.3
priority: high
type: task
ordinal: 27000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add this repository root `.crew.toml` and use it as the live acceptance fixture for declarative crews. It bootstraps six retained specialists without defining a WorkflowActor or hardcoded workflow phases.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The root manifest declares exactly six stable agents covering architecture, UI/UX, actor-model plus GoAkt v4 specialization, development, review, and QA
- [ ] #2 Every agent has a bounded role-appropriate default system prompt that follows repository instructions, uses actor messaging, preserves one writer per worktree, and forbids pane injection or ordinary actor teardown
- [ ] #3 Fresh startup from a nested repository directory creates the six actors; repeated Pi starts and `/crew spawn` reuse the same six actors and runtimes with no duplicates
- [ ] #4 Live E2E proves one normal task/completion exchange, metadata/activity projection, retained participants, restart/reconnect recovery, sanitized UI, and no WorkflowActor dependency
- [ ] #5 Roadmap, architecture, subagent, tool, and removal-parity documentation describes `.crew.toml`, automatic startup, explicit spawn, idempotency, and rollback/removal behavior
<!-- AC:END -->
