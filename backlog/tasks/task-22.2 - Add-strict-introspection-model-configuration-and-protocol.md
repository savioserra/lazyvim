---
id: TASK-22.2
title: Add strict introspection model configuration and protocol
status: In Progress
assignee:
  - '@pi'
created_date: '2026-09-02 06:10'
updated_date: '2026-09-02 06:56'
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

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add required strict `[hosted_pi].introspection_model` parsing and exact provider/model validation, wire it into the daemon-only introspection configuration, and update the managed private template, recognizer, verification, and docs without changing hosted worker launch arguments.\n2. Add additive typed thread/turn/scheduler-lease/run-counter settlement fields at the bridge protocol boundary plus bounded internal introspection request/result types; preserve compatibility and regenerate Go/TypeScript bindings.\n3. Implement an injectable `hostedpi.IntrospectionRunner` that launches exact-model Pi RPC with `--no-session --no-tools --no-extensions --no-prompt-templates`, bounded JSONL framing, strict final-assistant JSON parsing, duplicate/extra-key rejection, policy redaction, timeout, and process cleanup.\n4. Add deterministic config, protocol/codegen, parser, bounds, isolation-argument, timeout, malformed-output, redaction, and compatibility tests; run focused race tests and all fast repository gates.\n5. Obtain independent read-only review, integrate the reviewed commit, deploy the required managed setting, then finalize TASK-22.2 before starting scheduler persistence.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented first focused slice on main: required exact provider/model validation in the production owner-private config loader; managed template pins openai-codex/gpt-5.6-sol; Lua managed-config verification enforces the same bounded shape; daemon service config receives the value without adding it to hosted worker runtime launch arguments. Added accepted-corpus and malformed/missing/bare/control/extra-slash coverage. Config/cmd race tests and capability tests pass.
<!-- SECTION:NOTES:END -->
