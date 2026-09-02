---
id: TASK-1.1.1
title: Preserve actor work continuity across Pi compaction
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 05:52'
updated_date: '2026-09-02 06:01'
labels: []
dependencies:
  - TASK-22
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

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reproduce and map Pi compaction/session restore hooks against actor-client and hosted bridge projection persistence.
2. Preserve bounded private pending intent and outbound report obligations across compaction without making Tell ACKs model-visible.
3. Add compaction/reconnect/restart tests, then run a fresh-process forced-compaction E2E.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Live observation: after terminal compaction, actor Tell delivery ACKs continued arriving but the PM only classified them and retained agents left requested reports/actions in local panes. Hosted source records showed no outbound report receipts for architecture, UX, QA, or reviewer despite explicit report instructions. Current actor-client and hosted bridge code register no session_before_compact continuity hook. PM took writer ownership on main and explicitly paused the prior UI implementer assignment.

Superseded as the immediate writer focus by TASK-22 durable threads. Terminal projection continuity remains this task; hosted outbound-report obligation and automatic resumption depend on TASK-22 daemon-authoritative thread scheduling.
<!-- SECTION:NOTES:END -->
