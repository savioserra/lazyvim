---
id: TASK-1.1
title: Wire responsive actor conversation widgets into production
status: In Progress
assignee:
  - '@pi'
created_date: '2026-09-02 02:56'
updated_date: '2026-09-02 03:02'
labels: []
dependencies:
  - TASK-6
references:
  - docs/architecture/subagents/ACTOR-UX-DESIGN-SYSTEM.md
  - home/dot_pi/private_agent/extensions/actor-client
parent_task_id: TASK-1
priority: high
type: feature
ordinal: 19000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Replace the actor-client's remaining legacy communication renderer path with production use of the shipped XState render snapshots and responsive Pi TUI widgets. Implement the approved incoming/outgoing Tell, incoming request, combined Ask/reply, hidden pending status, busy/failure, compact tool, theme invalidation, and narrow/wide behavior without changing daemon authority or model-visible correlation content.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Registered Pi message and entry renderers consume bounded XState-derived snapshots rather than the legacy hosted-bridge card renderer
- [ ] #2 Incoming Tell, outgoing Tell, incoming request, combined Ask/reply, pending, busy, and failure states match the approved semantic wording and never duplicate conversation items
- [ ] #3 Wide and narrow layouts use Pi TUI components and theme tokens, stay within width, invalidate on theme changes, and preserve semantics on resize
- [ ] #4 Collapsed/expanded tool rendering is compact for humans while model-visible content retains required correlation and next-action fields
- [ ] #5 Automated and live fresh-runtime E2E cover Actor UX acceptance items 1-10 and 12 except typed productive phase, which is tracked separately
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Audit current renderer registration and snapshot-to-widget integration against the approved design system.
2. Define the smallest production adapter contract from root XState render snapshots to Pi renderers and tools.
3. Implement with one writer, add width/theme/replay and real adapter tests, then run independent review/QA.
4. Apply, reload, and execute the bounded live acceptance matrix without pane injection or scraping.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Initial PM audit after TASK-6: XState projection modules and widgets exist, but production renderer registration in actor-client/index.ts still calls the hosted-pi-bridge legacy renderCommunicationCard helper; the new renderProjectionConversationCard/renderActorStatusWidget are not the production conversation path. TASK-1.1 closes this integration gap. UX and architecture audits were assigned through owned actor sequences 34 and 35 before the sole writer starts.

Architecture audit sequence 35 returned the frozen production integration contract. Root projection remains the only state transaction; Pi renderers consume a schema-versioned actor-client render envelope and prefer renderSnapshot.card, with a read-only legacy CommunicationView adapter for persisted sessions. Add projections/{legacy,render-envelope}.ts and widgets/tool-renderers.ts; wire index.ts/handlers.ts; derive pending status from selectors; replace fixed width 100 with width-aware render/invalidate; preserve model correlation content; restore pending then terminal so terminal wins; never append on width/theme changes; add production adapter, migration, tool, width, theme, restore, replay, collision, and redaction tests. UX sequence 34 confirmed it returned its audit but omitted the matrix payload; the approved ACTOR-UX-DESIGN-SYSTEM remains the exact wording and acceptance authority, so implementation need not wait on another UX round.
<!-- SECTION:NOTES:END -->
