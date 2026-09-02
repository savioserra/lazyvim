---
id: TASK-17
title: >-
  Deprecate pi-subagents and tmux-subagents in favor of the workstation
  extension
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 02:38'
updated_date: '2026-09-02 02:41'
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
Deprecate the managed upstream `pi-subagents` Pi package and the repository-managed `tmux-subagents` observer extension/lifecycle package. The replacement is the workstation extension, which ships the owned distributed-agent framework and its actor-client/UI surfaces. Treat both legacy packages as compatibility-only removal inventory: neither may gain new workflow authority, product behavior, or architectural dependencies while the workstation extension reaches parity.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Documentation and package discovery identify both `pi-subagents` and `tmux-subagents` as deprecated and name the workstation extension as their replacement
- [ ] #2 Deprecation preserves existing installations without making either legacy package authoritative for owned actor execution, messaging, lifecycle, or UI state
- [ ] #3 Repository guidance prevents new features or dependencies from being added to either deprecated package
<!-- AC:END -->
