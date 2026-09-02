---
id: TASK-1.1.1
title: Preserve actor work continuity across Pi compaction
status: To Do
assignee: []
created_date: '2026-09-02 05:52'
labels: []
dependencies: []
references:
  - home/dot_pi/private_agent/extensions/actor-client
  - home/dot_pi/private_agent/extensions/hosted-pi-bridge
parent_task_id: TASK-1.1
priority: high
type: bug
ordinal: 34000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Preserve terminal and hosted actor conversation/work continuity when native Pi compaction occurs while an Ask, Tell-driven task, completion, or report is in flight. Compaction must not erase the private intent needed for the model to continue, turn a terminal acknowledgement into actionable content, or require the operator to remind the model to resume.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A pending Ask compacted before its reply retains its authoritative kind, correlation, private bounded original intent, and pending projection; the eventual reply wakes the model and continues the requested work exactly once
- [ ] #2 A Tell acknowledgement remains TUI-only before and after compaction and never creates an Ask reply, model-visible answer, or automatic model turn
- [ ] #3 Incoming actor work and outbound report obligations survive hosted Pi compaction and runtime/session reattachment without being left only in a local pane
- [ ] #4 Session restore and reconnect reconcile compacted, completed-before-compaction, completion-during-compaction, duplicate replay, and process-restart cases without lost or duplicated cards/actions
- [ ] #5 Compaction persistence is owner-private, bounded, schema-versioned, and never exposes prompts, answers, runtime identifiers, credentials, hosts, or tmux internals on public projections
- [ ] #6 Automated tests plus a fresh-process live E2E force compaction with work in flight and prove automatic post-compaction continuation without reminders, polling, or pane inspection
<!-- AC:END -->
