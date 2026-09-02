---
id: TASK-1.2.2
title: Build realtime footer and interactive actor status overlay
status: In Progress
assignee:
  - '@pi'
created_date: '2026-09-02 05:40'
updated_date: '2026-09-02 14:29'
labels: []
dependencies:
  - TASK-1.2.1
  - TASK-21
references:
  - home/dot_pi/private_agent/extensions/actor-client/index.ts
  - home/dot_pi/private_agent/extensions/actor-client/projections
  - home/dot_pi/private_agent/extensions/actor-client/widgets
  - >-
    /home/shyylol/.local/opt/nvm/versions/node/v24.19.0/lib/node_modules/@earendil-works/pi-coding-agent/docs/tui.md
modified_files:
  - home/dot_pi/private_agent/extensions/actor-client/index.ts
  - home/dot_pi/private_agent/extensions/actor-client/projections/activity.ts
  - home/dot_pi/private_agent/extensions/actor-client/projections/events.ts
  - home/dot_pi/private_agent/extensions/actor-client/projections/layout.ts
  - home/dot_pi/private_agent/extensions/actor-client/projections/machine.ts
  - home/dot_pi/private_agent/extensions/actor-client/projections/roster.ts
  - home/dot_pi/private_agent/extensions/actor-client/projections/sanitize.ts
  - home/dot_pi/private_agent/extensions/actor-client/projections/selectors.ts
  - home/dot_pi/private_agent/extensions/actor-client/projections/types.ts
  - >-
    home/dot_pi/private_agent/extensions/actor-client/widgets/actor-status-overlay.ts
  - tests/actor-client/handlers.test.mjs
  - tests/actor-client/projections.test.mjs
parent_task_id: TASK-1.2
priority: high
type: feature
ordinal: 31000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Project authenticated roster/activity frames through the existing actor-client XState root into an immediate compact footer and a bounded interactive `/actor-status` overlay. Both views consume one immutable disposable snapshot and never query actor_list for refresh.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Every accepted topic frame immediately rebuilds the compact footer with connection, display name, lifecycle, activity, pending request, and bounded overflow semantics
- [ ] #2 `/actor-status` opens a Pi TUI overlay with keyboard selection/cancel, narrow fallback, visible status details, and live rerender from the same XState snapshot while open
- [ ] #3 The overlay is read-only projection UI; it exposes no stop/control actions, credentials, principals, fences, runtime IDs, PIDs, tmux IDs, prompts, answers, or raw payloads
- [ ] #4 Unknown activity labels naturalize safely, clear removes only activity, lifecycle/activity remain separate, and stale/gapped/reconnect frames never flash older state
- [ ] #5 TUI tests cover theme invalidation, ANSI width, 20/25/49/80 columns, overlay input/focus/disposal, live update rendering, non-TUI no-op, reconnect, and no polling
- [ ] #6 Footer and overlay wording is copy-reviewed for one semantic fact per location; lifecycle/activity/pending/visibility labels are not redundantly repeated between row, detail, and footer
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Inspect actor-client extension state, projections, widgets, and tests on current origin/main.
2. Add a typed activity/thread projection adapter and reducer with epoch/sequence/reset/gap/clear fences, then derive one immutable actor UI snapshot used by footer and overlay.
3. Register read-only /actor-status rendering with keyboard expand/close behavior, live requestRender integration, sanitized non-TUI fallback, and remove stale literal redaction lifecycle wording.
4. Add width, ANSI, theme invalidation, keyboard, reconnect/fencing, fallback, and no-polling tests; run relevant extension checks; update Backlog and commit.

5. Address review findings: fence reconnect/subscribing before reset/replay, expose connection state in footer, switch fallback to ctx.mode, and remove split roster authority. Keep TASK-1.2.1 wire as an explicit dependency rather than inventing fields.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Information-hierarchy correction: interactive status remains payload-free. Actual Tell/Ask content expansion belongs to TASK-1.1 private conversation/tool balloons, while TASK-1.2.2 status rows avoid redundant labels and link users to conversation history rather than leaking payloads.

UX Ask 85 returned from a stale research worktree and is not authoritative for current implementation state. Its claims that actor_tell routes through Ask, compact Ask/Tell wording is shared, canonical completion keys are request-derived, and 20/25/49/80 tests are absent are superseded by current main. Retain only still-current UX evidence: `/actor-status` is not implemented; tool expansion relies on Pi defaults without keyboard/live acceptance; custom message renderers ignore expanded/collapsed options; public status must remain payload-free; exact copy matrix recommends narrow `actors +N`, bounded content in private conversation cards, and no duplicated state labels.

Adopted UI/UX contract: one immutable projection snapshot feeds both a width-safe compact footer and read-only /actor-status overlay; public fields remain lifecycle-only, owner-private fields use bounded activity/thread buckets active/resumable/waiting/blocked/completed. Overlay keyboard: up/down, enter/space expand, esc/ctrl-c close; non-TUI sanitized table fallback.

Reviewer on deployed 3b9dc40 confirms Critical missing /actor-status, split status keys, unused status widget, and stale literal [redacted] lifecycle copy. Implementation must register overlay and derive one footer/overlay snapshot after TASK-1.2.1.

Implemented UI-only actor activity/status projection: added activity adapter/reducer with epoch/sequence/reset/gap/clear fencing, one immutable actorStatus snapshot/footer selector, read-only /actor-status overlay/fallback, live requestRender listeners, and removed the literal lifecycle redaction prefix. Validation: npm test --prefix home/dot_pi/private_agent/extensions/actor-client passed (46/46); git diff --check passed; nvim -l tests/capabilities.test.lua passed. Broader tmux-subagents tests were run and only tmux-dependent cases failed because tmux is not installed (spawn tmux ENOENT); chezmoi dry-run likewise failed at command -v tmux.

Review reopened: commit c2f8173 was rejected pending stale reconnect/subscribing fencing, explicit disconnected footer state, documented non-TUI fallback semantics, single projection authority, and real TASK-1.2.1 wire delivery. Reopened before applying follow-up fixes; will not mark Done until wire delivery is present.

Review fixes implemented after reopening: cherry-picked TASK-1.2.1 protocol/runtime commit d4805bc, wired generated agentActivityFrame and bridgePushFrame.activityFrames into the existing ACTIVITY adapter boundary, changed reconnect/subscribing to render unavailable rows until a fresh reset/replay is accepted, made disconnected footer state explicit before pending/activity facts, switched fallback gating to ctx.mode !== "tui", and made the legacy roster helper derive from the same projection snapshot. Validation: actor-client tests pass 48/48; nvim capability test passes; git diff --check passes.
<!-- SECTION:NOTES:END -->
