---
id: TASK-22.2
title: Add strict introspection model configuration and protocol
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 06:10'
labels: []
dependencies:
  - TASK-22.1
parent_task_id: TASK-22
priority: high
type: feature
ordinal: 37000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add the exact private introspection model setting and typed bounded daemon/hosted-bridge messages needed to request and commit structured thread introspection without changing the worker model.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Private config requires and validates an exact introspection_model when hosted Pi is enabled and passes it only to the isolated introspection path
- [ ] #2 Typed protocol messages carry opaque thread/turn/lease identity and bounded structured results without exposing credentials, runtime IDs, prompts, or answers publicly
- [ ] #3 Codegen, config, redaction, malformed-result, compatibility, and deployment documentation tests pass
<!-- AC:END -->
