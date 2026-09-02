---
id: TASK-1.1
title: Wire responsive actor conversation widgets into production
status: In Progress
assignee:
  - '@pi'
created_date: '2026-09-02 02:56'
updated_date: '2026-09-02 03:28'
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
- [x] #1 Registered Pi message and entry renderers consume bounded XState-derived snapshots rather than the legacy hosted-bridge card renderer
- [x] #2 Incoming Tell, outgoing Tell, incoming request, combined Ask/reply, pending, busy, and failure states match the approved semantic wording and never duplicate conversation items
- [x] #3 Wide and narrow layouts use Pi TUI components and theme tokens, stay within width, invalidate on theme changes, and preserve semantics on resize
- [x] #4 Collapsed/expanded tool rendering is compact for humans while model-visible content retains required correlation and next-action fields
- [ ] #5 Automated and live fresh-runtime E2E cover Actor UX acceptance items 1-10 and 12 except typed productive phase, which is tracked separately
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add schema-versioned actor-client render envelopes plus read-only legacy CommunicationView/line migration adapters. 2. Wire index entry/message renderers and tool renderers to actor-client widgets from XState snapshots, preserving model-visible correlation content. 3. Make conversation/status widgets width-aware/theme-invalidating and selector-driven without append-on-resize/theme. 4. Add adapter, migration, restore/replay/collision, tool, redaction, and narrow/wide tests; run relevant gates and commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Initial PM audit after TASK-6: XState projection modules and widgets exist, but production renderer registration in actor-client/index.ts still calls the hosted-pi-bridge legacy renderCommunicationCard helper; the new renderProjectionConversationCard/renderActorStatusWidget are not the production conversation path. TASK-1.1 closes this integration gap. UX and architecture audits were assigned through owned actor sequences 34 and 35 before the sole writer starts.

Architecture audit sequence 35 returned the frozen production integration contract. Root projection remains the only state transaction; Pi renderers consume a schema-versioned actor-client render envelope and prefer renderSnapshot.card, with a read-only legacy CommunicationView adapter for persisted sessions. Add projections/{legacy,render-envelope}.ts and widgets/tool-renderers.ts; wire index.ts/handlers.ts; derive pending status from selectors; replace fixed width 100 with width-aware render/invalidate; preserve model correlation content; restore pending then terminal so terminal wins; never append on width/theme changes; add production adapter, migration, tool, width, theme, restore, replay, collision, and redaction tests. UX sequence 34 confirmed it returned its audit but omitted the matrix payload; the approved ACTOR-UX-DESIGN-SYSTEM remains the exact wording and acceptance authority, so implementation need not wait on another UX round.

Implemented production widget wiring: schema-versioned render envelopes, read-only legacy migration adapters, actor-client entry/message/tool renderers, width-aware theme-token widgets, selector-driven pending status, terminal-first restore compatibility, and no resize/theme append path. Added tests for envelope rendering, legacy migration, pending wording, tool collapsed/expanded renderers, renderEnvelope persistence, width/theme/resize, restore/replay/collision, and redaction.

Validation: actor-client 37/37 passed; hosted bridge 36/36 passed; capabilities passed; services npm/codegen/go test -race/go vet/npm protocol passed; git diff --check passed. tmux-subagents remains 93/97 with four tmux ENOENT cases on this host; stylua and chezmoi dry-run remain blocked by missing stylua/tmux.

Writer completion sequence 36 integrated as production code commit: render envelopes, legacy read-only conversion, snapshot-first registered renderers, width/theme-aware actor-client cards, selector pending status, and compact/expanded tool widgets. Writer gates passed actor-client 37/37, hosted bridge 36/36, capabilities, services codegen/race/vet/protocol, and diff check. Independent review/QA and local full gates follow before apply/reload.

PM post-integration gates on 3e5d282 passed: actor-client 37/37, hosted bridge 36/36, capabilities, service codegen/go race/vet/protocol 6/6, legacy observer 97/97 with /snap/bin/tmux, git diff check, and scratch chezmoi dry-run. Independent reviewer sequence 37 and QA sequence 38 are active before apply/reload/live matrix.

Independent reviewer sequence 37 found two P0 blockers: incoming regular Tell/request still carries only legacy CommunicationView and is rendered via conversion without DELIVERY.INCOMING projection/render-envelope production events; and conversation-card width enforcement uses raw string length/slice after theme styling, corrupting ANSI and dropping semantics. Existing 37 tests use migration/no-op theme paths and miss both seams. TASK-1.1 cannot deploy until corrected and re-reviewed.

Baseline QA sequence 38 returned a conditional pass but did not exercise the two reviewer P0 seams; it is superseded by sequence 37 findings. QA must rerun after sequence 40 with live incoming projection-envelope and real-ANSI narrow-width coverage.

P0 correction 3cc7aab integrated: live regular Tell/request now reduces DELIVERY.INCOMING events through root projection and persists schema-versioned render envelopes; legacy CommunicationView is migration-only; raw themed slicing replaced with Pi TUI truncateToWidth; real ANSI width tests cover 20, 25, 49, and 80 columns. Writer actor-client suite passed 40/40 and full relevant gates.
<!-- SECTION:NOTES:END -->
