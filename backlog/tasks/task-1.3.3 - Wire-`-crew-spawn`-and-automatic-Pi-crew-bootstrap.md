---
id: TASK-1.3.3
title: Wire `/crew spawn` and automatic Pi crew bootstrap
status: To Do
assignee:
  - '@pi'
created_date: '2026-09-02 04:46'
updated_date: '2026-09-02 04:46'
labels: []
dependencies:
  - TASK-1.3.2
references:
  - home/dot_pi/private_agent/extensions/actor-client/index.ts
  - home/dot_pi/private_agent/extensions/actor-client/handlers.ts
  - tests/actor-client
parent_task_id: TASK-1.3
priority: high
type: feature
ordinal: 26000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Expose crew reconciliation through actor-client. `/crew spawn` can consume supplied TOML contents or the discovered project-root manifest, while ordinary Pi startup automatically invokes the same path after authentication.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 `/crew spawn` with TOML contents validates and reconciles that manifest, while `/crew spawn` without contents uses the discovered root `.crew.toml`
- [ ] #2 Starting Pi inside a configured project automatically invokes the same authenticated reconciliation once the actor client is ready; missing configuration causes no network mutation or noisy error
- [ ] #3 Each newly created hosted Pi runtime receives its configured `prompt` as default system prompt; existing retained actors are not silently restarted merely to reapply configuration
- [ ] #4 Command, tool, and startup summaries distinguish created, existing, skipped, and conflict outcomes without exposing full prompts or private actor/runtime data
- [ ] #5 Reload, reconnect, repeated command, and simultaneous terminal tests prove the client path remains idempotent and does not duplicate runtimes, cards, or status entries
<!-- AC:END -->
