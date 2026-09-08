---
id: TASK-1.1
title: Wire responsive actor conversation widgets into production
status: In Progress
assignee:
  - '@pi'
created_date: '2026-09-02 02:56'
updated_date: '2026-09-02 13:57'
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
- [ ] #2 Incoming Tell, outgoing Tell, incoming request, combined Ask/reply, pending, busy, and failure states match the approved semantic wording and never duplicate conversation items
- [x] #3 Wide and narrow layouts use Pi TUI components and theme tokens, stay within width, invalidate on theme changes, and preserve semantics on resize
- [ ] #4 Collapsed/expanded tool rendering is compact for humans while model-visible content retains required correlation and next-action fields
- [ ] #5 Automated and live fresh-runtime E2E cover Actor UX acceptance items 1-10 and 12 except typed productive phase, which is tracked separately
- [ ] #6 Deployment documentation and live acceptance require a full terminal Pi process restart for actor-client changes; `/reload` alone is explicitly insufficient
- [ ] #7 Conversation and tool copy has one clear information hierarchy: each state/action label appears once, with no duplicate wording such as applied/delivered/replied repeated in title, body, and footer
- [ ] #8 Private conversation cards preserve the actual bounded Tell body, Ask prompt, and answer; collapsed views show a useful sanitized preview and expanded views show full bounded content plus correlation details without exposing it on public status surfaces
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add schema-versioned actor-client render envelopes plus read-only legacy CommunicationView/line migration adapters. 2. Wire index entry/message renderers and tool renderers to actor-client widgets from XState snapshots, preserving model-visible correlation content. 3. Make conversation/status widgets width-aware/theme-invalidating and selector-driven without append-on-resize/theme. 4. Add adapter, migration, restore/replay/collision, tool, redaction, and narrow/wide tests; run relevant gates and commit.

5. Close the production intent gap: hosted `actor_tell` must use TELL admission semantics and display delivered/failure states; add a distinct `actor_ask` command/tool for request/reply semantics, preserving model correlation and compatibility documentation.

6. Separate terminal completion presentation by protocol intent: Tell acknowledgement may update a TUI-only delivered/failure projection but must never create an Actor Ask reply, trigger a model turn, or expose delivery acknowledged as an answer; Ask alone owns model-visible reply completion.

7. UI-only correction on origin/main: gate actorMessageReplyFrame presentation so Tell/notification terminal ACKs update cursors without creating actor-client-ask-completion cards/model turns; keep Ask/prompt completions unchanged.
8. Add private tool/conversation preview hierarchy tests for Tell/Ask collapsed renderers and non-duplicated Tell ACK semantics; run actor-client/hosted fast suites and diff checks.
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

Focused independent re-review sequence 41 explicitly approved the incoming projection-envelope production path, legacy-only fallback, no duplicate request, ANSI-safe width handling at 20/25/49/80, and 40/40 actor-client tests. AC 1-4 are verified; AC 5 remains open for post-apply/reload live UX matrix, currently gated by TASK-19 terminal delivery reliability.

Correction QA sequence 42 conditionally passed the requested code seams; its hosted environment lacked tmux. PM-host evidence supersedes that environment block: legacy observer 97/97 and scratch chezmoi dry-run passed with /snap/bin/tmux. TASK-1.1 now awaits only the live acceptance matrix after TASK-19.

Deployment/live matrix will use the operator-requested fresh crew reset recorded in TASK-19: exact teardown only after apply, fresh daemon actor state, recreated five UI actors, and a rebuilt labeled 3x2 crew window while preserving/reconnecting the PM session safely.

Fresh deployment reset completed with new service/frontend files applied and a rebuilt five-actor crew. Final live UI matrix awaits PM /reload and post-reload traffic.

Live roadmap audit found the hosted `actor_tell` tool and `/actor-tell` command still call message mode 2 (ASK), despite their Tell labels. Synthetic projection tests do not prove production Tell semantics. AC 2 and 4 are reopened until true Tell and distinct Ask tools/cards pass live E2E.

Writer sequence 50 integrated: hosted /actor-tell and actor_tell now use protocol TELL; distinct /actor-ask and actor_ask use ASK; UI/model wording separates delivered from replied while preserving correlation. Writer gates passed 78 combined actor/bridge tests, service codegen/race/vet/protocol, capabilities, diff, and scratch apply. Task remains open for independent review and live matrix.

Independent review sequence 59 verified Tell/Ask wire modes, regular-client tool semantics, three-consecutive completion regression, stale-fence retry evidence, canonical routing, dynamic metadata authority, and core redaction. One Medium blocker remains: hosted communication-ui renderToolResult fast path maps a pending actor_ask CommunicationView to ✓ delivered. It must render admitted/waiting, and production-path tests must cover the CommunicationView branch.

Writer sequence 61 correction integrated: hosted renderToolResult now presents a pending actor_ask CommunicationView as waiting rather than delivered, with production-path pending/replied/failed Ask and delivered/failed Tell coverage. Original writer commit 1ca7d0d; integrated code commit recorded in Git history. Task remains open for PM verification and independent re-review.

PM verification on integrated main 862a9fc: hosted-pi-bridge suite passed 38/38 including production tool result renderer Ask/Tell semantic coverage; git diff --check passed and tree is clean. Independent final review remains required.

Deployment verify found stale lifecycle expectations for removed actor-send command. Updated subagents verifier to require the current actor-connect/list/resolve/health/tell/ask/create/stop/control/subscription command surface and confirm hosted bridge registers none outside hosted runtime; direct source verifier passed.

Operator-authorized deployment completed: exactly stopped five hosted UI actors, ran chezmoi source apply, rebuilt/restarted daemon, recreated all five fresh hosted runtimes from their worktrees with current display/role metadata, and confirmed deployed actor-client/hosted bridge files match source. Workstation verify passed after fixing the stale command-surface verifier. Current interactive Pi still requires `/reload` to load the deployed actor-client code.

Operator deployment correction: Pi `/reload` is not sufficient for actor-client releases. Treat actor-client command/tool registrations, loaded closures, protobuf/runtime modules, and XState/session projections as process-lifetime state. Deployment acceptance requires exiting and starting a new terminal Pi process (continuing the intended native Pi session explicitly where supported), then proving the new process exposes current Tell/Ask semantics and UI.

Fresh terminal Pi process after deployment now exposes true TELL semantics: actor_tell sequences 68-70 returned kind=Tell and rendered ✓ delivered rather than pending/replied. This proves full-process restart activated the new tool registration; remaining live matrix still needs Ask/reply and incoming/failure cases.

Fresh-process live sequence 69 exposed a new blocker: initial actor_tell correctly rendered ✓ delivered/kind=Tell, but its terminal delivery ACK later entered the generic actorMessageReplyFrame path and rendered `Actor Ask replied` with answer `delivery acknowledged`. Tell terminal ACKs must not use actor-client-ask-completion or replied semantics.

Sequence 70 independently reproduced the same Tell terminal misclassification against UI QA, confirming the defect is deterministic across targets rather than a one-off replay artifact.

Operator UX feedback: balloons currently repeat information (for example the same applied/state wording can appear twice) while hiding the actual message. Copy review must remove redundant title/body/footer labels and make message content available through collapsed preview plus expansion. Public footer/roster remains payload-free; content is limited to the private requesting conversation/tool renderer.

UI-only origin/main correction implemented in isolated worktree: actorMessageReplyFrame presentation is now Ask/prompt/request only, so Tell/notification terminal ACKs only advance the mutation high-water and never create actor-client-ask-completion, replied cards, or model turns. Collapsed actor-client tool results now include a bounded sanitized private preview from the conversation card body/reply while expanded rendering keeps the full conversation envelope. Validation: actor-client npm test 42/42 passed; hosted-pi-bridge npm test 38/38 passed; capabilities passed; tmux-subagents remains 93/97 blocked by tmux ENOENT in this host PATH; stylua blocked by missing stylua; chezmoi dry-run passed with /snap/bin on PATH; git diff --check passed.

QA post-fix matrix: unit coverage is strong; remaining acceptance is fresh-terminal live proof that Tell yields one private delivered/failed card and never an Ask reply or model-visible delivery acknowledgement, followed by one real Ask reply. Full Pi restart required.

Reviewer found hosted production still registers/appends legacy CommunicationView/renderCommunicationCard paths rather than schema-versioned render envelopes/widgets. Assigned follow-up implementation with no cross-extension runtime imports.

Implemented hosted production schema-v1 local render envelopes and expanded conversation widget parity without cross-extension runtime imports (babc3a3). Actor message tool results now carry communicationView plus renderEnvelope. Fresh live acceptance remains.

Fresh terminal restart live proof after 3d68ca2+: outgoing Tell sequence 29 rendered one compact delivered result and produced no model-visible Ask completion; outgoing Ask sequence 30 returned ASK_UI_OK exactly once through the Ask completion card. This verifies the Tell/Ask split for the two canonical outgoing cases; incoming/busy/failure and full copy hierarchy matrix remain.
<!-- SECTION:NOTES:END -->
