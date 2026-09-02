---
id: TASK-1.3
title: Exercise WorkflowActor UX with worker reviewer QA and decisions
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 02:56'
updated_date: '2026-09-02 02:56'
labels: []
dependencies:
  - TASK-1.2
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
Drive a real worker -> reviewer -> QA -> correction workflow through an owned WorkflowActor without Project Manager UI dependence. Project evidence-correct progress and one durable user decision through the same actor-client XState contract, retaining workflow participants and enforcing one writer per worktree.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 WorkflowActor durably coordinates worker, reviewer, QA, correction, and retained participant routing without terminal automation or dual writers
- [ ] #2 Frontend renders topic-backed workflow progress and one replay-deduplicated durable decision card without becoming workflow authority
- [ ] #3 Requester disconnect/reload preserves workflow state, pending decision, completion routing, and exactly-once presentation
- [ ] #4 Live E2E records evidence-correct phase transitions, decision continuation, final completion, and no PM UI dependency
<!-- AC:END -->
