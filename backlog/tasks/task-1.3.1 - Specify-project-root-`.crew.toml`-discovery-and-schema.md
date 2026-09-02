---
id: TASK-1.3.1
title: Specify project-root `.crew.toml` discovery and schema
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 04:46'
labels: []
dependencies: []
references:
  - services/subagents/api/subagents/v1/subagents.proto
  - home/dot_pi/private_agent/extensions/actor-client/index.ts
  - docs/subagents.md
parent_task_id: TASK-1.3
priority: high
type: feature
ordinal: 24000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Define the versioned declarative crew manifest and deterministic discovery contract used by both automatic Pi startup and explicit crew spawning. The manifest describes long-lived logical agents and default hosted Pi prompts; it is configuration, not workflow state.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Discovery from any current working directory resolves one canonical project root and optional root `.crew.toml` without leaking into unrelated parent projects; no manifest is a clean no-op
- [ ] #2 The versioned TOML schema supports stable agent ID, display name, dynamic role metadata, and bounded per-agent `prompt` system text; optional fields have explicit types, bounds, and defaults
- [ ] #3 Validation rejects duplicate IDs, malformed or unsupported fields, unsafe identities, unbounded content, and ambiguous roots before any actor is spawned
- [ ] #4 Prompt, display name, and role remain presentation/runtime configuration and cannot replace stable routing identity or transport authorization
- [ ] #5 Parser/discovery tests cover nested directories, symlinks/root boundaries, missing files, valid multiline prompts, duplicate agents, invalid bounds, and deterministic normalized digests
<!-- AC:END -->
