---
id: TASK-17
title: Deprecate tmux-subagents in favor of the workstation extension
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 02:38'
labels: []
dependencies: []
references:
  - docs/subagents.md
  - docs/architecture/subagents/ROADMAP.md
priority: high
type: chore
ordinal: 17000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deprecate the repository-managed `tmux-subagents` Pi observer extension and its lifecycle package. The replacement is the workstation extension, which ships the owned distributed-agent framework and its actor-client/UI surfaces. Treat `tmux-subagents` as compatibility-only removal inventory: it must not gain new workflow authority, product behavior, or architectural dependencies while the workstation extension reaches parity.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Documentation and package discovery identify `tmux-subagents` as deprecated and name the workstation extension as its replacement
- [ ] #2 The deprecation preserves existing installations without making `tmux-subagents` authoritative for owned actor execution, messaging, lifecycle, or UI state
- [ ] #3 Repository guidance prevents new features or dependencies from being added to the deprecated extension
<!-- AC:END -->
