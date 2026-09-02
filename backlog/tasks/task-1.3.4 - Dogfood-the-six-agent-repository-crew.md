---
id: TASK-1.3.4
title: Dogfood the supervised six-agent repository crew
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 04:46'
updated_date: '2026-09-02 05:25'
labels: []
dependencies:
  - TASK-1.3.5
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
Add this repository root `.crew.toml` and use it as the live acceptance fixture for declarative crews. It bootstraps six retained participant specialists plus one retained prompt-driven supervisor AgentActor without defining a WorkflowActor or hardcoded workflow phases.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The root manifest declares exactly six stable participants covering architecture, UI/UX, actor-model plus GoAkt v4 specialization, development, review, and QA, plus exactly one `[crew.supervisor]`
- [ ] #2 Every participant and the supervisor have bounded role-appropriate default system prompts that follow repository instructions, use actor messaging, preserve one writer per worktree, and forbid pane injection or ordinary actor teardown
- [ ] #3 Fresh startup from a nested repository directory creates six participants and one supervisor; repeated Pi starts and `/crew spawn` reuse those same actors and runtimes with no duplicates
- [ ] #4 Live E2E proves the supervisor observes crew-scoped topic state, assigns one normal task, receives completion, requests review/QA or correction through typed messages, retains all participants, and does not use WorkflowActor authority
- [ ] #5 Restart/reconnect restores supervised coordination and metadata/activity projections with sanitized UI and no polling, tmux scraping/injection, foreign mutation, dual writer, or automatic actor stop
- [ ] #6 Roadmap, architecture, subagent, tool, and removal-parity documentation describes `.crew.toml`, supervisor semantics, automatic startup, explicit spawn, idempotency, and rollback/removal behavior
<!-- AC:END -->
