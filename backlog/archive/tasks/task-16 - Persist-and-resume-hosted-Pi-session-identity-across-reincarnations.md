---
id: TASK-16
title: Persist and resume hosted Pi session identity across reincarnations
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 00:44'
labels: []
dependencies: []
references:
  - >-
    /home/shyylol/.local/opt/nvm/versions/node/v24.19.0/lib/node_modules/@earendil-works/pi-coding-agent/docs/sessions.md
modified_files:
  - services/subagents/internal/application/durable.go
  - services/subagents/internal/hostedpi/runtime.go
  - services/subagents/internal/actors/agent.go
  - services/subagents/internal/service/service.go
priority: high
type: enhancement
ordinal: 16000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Hosted AgentActor reincarnations currently launch Pi with only --session-dir and --name. Pi owns a stable session UUID (visible through /session, PI_SESSION_ID, and SessionManager.getSessionId), but the hosted durable record does not retain and pass that UUID back to Pi. A runtime bounce may therefore create a new Pi session and lose retained model context even though the logical AgentActor is stable. Persist the first authoritative hosted Pi session UUID and resume it on every later incarnation with pi --session <id>. This is separate from TASK-15 regular-terminal delivery starvation.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 First hosted launch creates a Pi session only when no durable Pi session UUID exists, then captures and durably commits the authenticated bridge PiSessionID
- [ ] #2 Every subsequent runtime reincarnation launches Pi with --session <durable-id> inside the owned session directory; --name remains display metadata only
- [ ] #3 Bridge connect/replacement rejects an unexpected Pi session UUID after durable identity is established instead of silently rotating context
- [ ] #4 Missing, corrupt, or path-escaping retained sessions fail closed with bounded diagnostics and an explicit operator recovery path
- [ ] #5 Restart/reincarnation integration proves the same Pi session UUID, conversation history, stable AgentActor identity, and mutation high-water survive
- [ ] #6 Terminal Pi continues deriving its stable client AgentActor identity from SessionManager.getSessionId without transport-session churn
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Extend durable hosted launch/binding state with the authoritative Pi session UUID. 2. Capture it from the first authenticated bridge connect and commit before readiness. 3. Add exact --session <id> launch on reincarnation and verify owned session-directory containment. 4. Fence bridge identity changes and add explicit recovery semantics. 5. Add runtime/service restart integration tests and update architecture documentation.
<!-- SECTION:PLAN:END -->
