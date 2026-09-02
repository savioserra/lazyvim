---
id: TASK-19
title: Fix consecutive ActorTaskCompleted presentation stalls
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 03:03'
labels: []
dependencies: []
references:
  - >-
    docs/architecture/subagents/0005-daemon-connected-bridge-and-frontend-projections.md
  - home/dot_pi/private_agent/extensions/actor-client/index.ts
  - services/subagents/internal/service/actor_reply_broker.go
priority: high
type: bug
ordinal: 22000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
After the corrected actor-client was applied and reloaded, fresh sequence 33 automatically presented, but later TASK-1.1 research completions 34 and 35 reached durable Project Manager source history with completed terminal state and zero source outbox while no model wake/conversation card appeared. The PM had to inspect durable state, which is diagnostic fallback rather than acceptable workflow. Diagnose push, attachment/fence, reply broker, root presentation, and persisted dedupe/cursor state so every consecutive completion wakes/presents exactly once without user reminders or polling.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Three or more consecutive fresh ActorTaskCompleted results automatically reach and wake the requesting terminal without another user turn, pane inspection, or durable-state polling
- [ ] #2 Reconnect/reload replays any committed but unpresented completion exactly once and never suppresses it because an earlier completion was presented
- [ ] #3 Presentation failure remains durable/retryable with bounded degraded status, and attachment/fence or reply-cursor errors cannot silently strand a completion
- [ ] #4 Service and actor-client regressions reproduce the sequence-33-success then sequence-34/35-stall class and prove the fix under reconnect
<!-- AC:END -->
