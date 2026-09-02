---
id: TASK-6
title: Review and QA gates for UI slice
status: In Progress
assignee:
  - '@pi'
created_date: '2026-08-31 21:41'
updated_date: '2026-09-02 02:46'
labels: []
dependencies:
  - TASK-5
priority: high
type: task
ordinal: 6000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Perform independent architecture review and QA of the XState projection and rich Pi TUI slice before deployment.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Reviewer verifies authority boundaries, deterministic reducers, exact-once rendering, and redaction
- [ ] #2 QA verifies reconnect/replay, stale cursors, Tell/Ask/completion cards, busy/failure states, and narrow/wide rendering
- [ ] #3 All actor-client, hosted bridge, codegen, Go, formatting, and dry-run apply gates pass or have documented environment-only blockers
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Conduct read-only architecture and security review.
2. Execute focused projection/widget tests and full relevant gates.
3. Return findings to the implementation writer for fixes; repeat until clean.
4. Perform local reload and live actor conversation E2E before finalization.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation commit fb812f4 was cherry-picked to main as a3c32c5. Independent review and QA are assigned read-only in isolated worktrees; all findings must be returned through ActorTaskCompleted before reload/live E2E.

Independent reviewer returned P0 production-wiring blockers at source sequence 28. Required fixes before approval: preserve daemon completionKey exactly and reconcile provisional pending IDs; wire PRESENTATION.SUCCEEDED/FAILED around awaited Pi adapter persistence so failure remains replayable and degrades without unhandled rejection; require SNAPSHOT_RESET as first frame of every higher epoch; remove legacy selector mutation; prevent ActorMessageResponse admission from projecting terminal completion; restore persisted pending/completion entries into root projection context; add actor-client_xstate 5.20.2 as a distinct managed versions.json key. Existing six focused projection tests pass but miss these production seams.

Baseline QA returned at source sequence 29 against a3c32c5/19f6539: focused/full code gates conditionally passed and worktree remained clean, but its hosted runtime PATH lacked tmux and stylua, blocking four tmux integration/smoke cases, chezmoi dry-run, and formatting. This does not override the independent review P0 findings; QA must rerun production-seam regressions after sequence 30 corrections.

Correction commit 918dd04 was integrated to main (without replacing concurrent Backlog history): canonical completion keys reconcile provisional pending entries; presentation success/failure is awaited and replayable; higher epochs require reset-first; admission cannot project completion; persisted projection entries restore terminal-first; legacy mutation is removed; actor_client_xstate has a separate managed version/integrity key. New production-seam regressions were added.
<!-- SECTION:NOTES:END -->
