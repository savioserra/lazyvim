---
id: TASK-27
title: Evaluate and adopt GoAkt v4 mechanisms in subagents service
status: To Do
assignee: []
created_date: '2026-09-02 22:37'
labels:
  - subagents
  - goakt
  - architecture
dependencies: []
references:
  - 'https://docs.goakt.dev/advanced/extensions-and-dependencies'
priority: medium
type: enhancement
ordinal: 43000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Review the current services/subagents codebase and identify places where GoAkt v4 already provides mechanisms we may be recreating. Plan and implement appropriate adoptions of framework-provided capabilities, such as extensions, dependency injection, and related advanced patterns, so the service relies on maintained GoAkt behavior instead of bespoke infrastructure where it is safe and worthwhile.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Current custom mechanisms in services/subagents that overlap with GoAkt v4 features are inventoried with file references.
- [ ] #2 Relevant GoAkt v4 mechanisms, including extensions and dependencies, are summarized with applicability and tradeoffs.
- [ ] #3 An implementation plan is recorded before code changes and distinguishes adopt-now opportunities from keep-custom decisions and follow-up tasks, if needed.
- [ ] #4 Selected adopt-now opportunities are implemented with tests and documentation updated where behavior or architecture changes.
- [ ] #5 Relevant subagents checks pass, including generated-boundary verification and Go/Node tests as applicable.
<!-- AC:END -->
