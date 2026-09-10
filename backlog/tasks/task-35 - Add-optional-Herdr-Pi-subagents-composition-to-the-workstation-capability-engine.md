---
id: TASK-35
title: >-
  Add optional Herdr + Pi/subagents composition to the workstation capability
  engine
status: In Progress
assignee:
  - '@operator'
created_date: '2026-09-08 23:47'
updated_date: '2026-09-10 16:20'
labels: []
dependencies:
  - TASK-34
references:
  - >-
    backlog/tasks/task-34 -
    Make-the-workstation-capabilities-engine-authoritative-over-chezmoi.md
  - 'https://github.com/herdrdev/herdr/releases/tag/v0.9.0'
  - >-
    https://github.com/herdrdev/herdr/blob/v0.9.0/src/integration/assets/pi/herdr-agent-state.ts
  - >-
    https://github.com/nicobailon/pi-subagents/blob/0fc0eebb9604970c506708b7508d6aa38921fde2/src/integrations/herdr-status.ts#L245-L281
  - >-
    https://github.com/earendil-works/pi/blob/d981de1229ef899957bbe968bc8dcda02a21f477/packages/coding-agent/src/core/extensions/loader.ts
documentation:
  - >-
    backlog/docs/doc-1 -
    Herdr-Pi-pi-subagents-engine-authoritative-capability-specification.md
type: feature
ordinal: 50000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Intent and status

After TASK-34 makes workstation authoritative, provide reproducibly pinned Herdr installation and the official Pi integration while preserving existing `pi` and `pi-subagents` identities, ownership and standalone headless operation. Capture both existing integration directions and verify actual compatibility, offline verification, update and user-state boundaries before promising support.

**Future work only: To Do, explicitly unassigned, blocked by TASK-34. No implementation, compatibility pass, or Herdr-specific design approval is implied. Imported into canonical Backlog through CLI after parent review; implementation remains future work.** Created in `/tmp/workstation-herdr-spec.jQkeOU`, branch `research/herdr-pi-spec`, snapshot `e809f40b5aef82e395a65dd101db00a5d0e64747`. The attached sourced specification preserves the complete research with recovered corrections. This description is durable context, not an execution plan; the plan field is intentionally absent.

TASK-34 is the user-approved architectural direction and overrides stale chezmoi-authority prose: workstation owns public apply/update/setup/sync/verify; packages provision through setup; chezmoi is a subordinate pure-home-state provisioner. A future worker must reread TASK-34's completed interfaces, provision context, selection surface and tests before planning implementation.

## Scope and capability relation (proposal)

- Proposed `herdr` capability owns a pinned user-local native binary and static verification. Herdr is an optional terminal UI/environment with an **upstream-owned bundled background server**, not a desktop GUI, repo Go service or replacement subagent engine.
- Proposed optional full-stack `herdr-pi` composition owns only the official Pi hook plus cross-package verification/docs. Preserve existing managed Node/Pi npm and pi-subagents installation/discovery, tools, skills and roles; use the native subagent bridge rather than a duplicate reporter.
- Required arrows (prerequisite → dependent): `foundation → node → pi → pi-skills`; `pi + pi-skills → pi-subagents`; `foundation → herdr`; `pi + herdr + pi-subagents → herdr-pi` **only when that full-stack composition is selected**. The last subagent edge is repository composition policy, not an upstream hook requirement. Neither Pi nor pi-subagents requires Herdr. No cycles or speculative optional-dependency schema. Installation opt-in remains a post-TASK-34 decision; runtime optionality is not an existing selection API.
- Herdr hosts/observes Pi terminals. Pi owns its sessions; pi-subagents owns child execution, control and artifacts. Subagents publishes current-session metadata, opens optional inspector dashboards through existing control channels, and can request separate project-owned Pi panes. **No Herdr authority to attach/adopt/move existing headless runs.** Inspector close does not stop children; peer panes are independent sessions.

## Platform and integrity baseline (candidate; not executed)

| Target | Herdr candidate asset | Publisher SHA-256 |
|---|---|---|
| Linux x86_64 | https://github.com/herdrdev/herdr/releases/download/v0.9.0/herdr-linux-x86_64 | `4fa1a01158dd8043da92d31b270780b0dcc10603038d9b61cac4d81ab63fb71f` |
| WSL-as-Linux x86_64 | Same Linux asset; mapping proposal, not runtime certification | Same Linux digest |
| macOS arm64 | https://github.com/herdrdev/herdr/releases/download/v0.9.0/herdr-macos-aarch64 | `32b53df09872628059c789a69f02a6b8e29e14ddf26711421f3463f70c1aef17` |

Research baseline: Herdr 0.9.0 / bundled Pi integration revision 8; Pi 0.85.1; pi-subagents 0.66.0. Preserve exact existing npm registry integrities (recorded in the specification and `workstation/versions.json`). Binary digests are publisher metadata, not independent hashing; the hook byte hash is still required. Linux libc/OS minima, WSL execution and macOS signing/quarantine need validation. No native Windows/other-architecture commitment or silent OS-package prerequisite installation. No silent pin bump.

## Setup / sync / verify and state ownership

Workstation provisions bytes/config via package setup: `herdr` owns its binary; composition owns only the official hook at the effective Pi agent directory. Decide guarded official installer versus checksum-pinned official file, with ownership/hash checks, idempotence and atomic activation policy. Existing unrelated files win unless the user explicitly approves takeover; a version marker alone is not ownership proof. Respect target home and `PI_CODING_AGENT_DIR` consistently. Do not exact-manage whole Pi/Herdr/project trees or clobber settings.

No initial sync handler is needed. Setup/sync/normal verify must not start/stop/restart/adopt a server or child, open panes, scan live sessions, invoke model/vault APIs or resolve credentials. Normal verify uses isolated trusted loader resources and synthetic fixtures, not ambient user extensions; `PI_OFFLINE` alone is not a sandbox. Human-only runtime launch/reattach/stop is separate. Detach is not stop; installed-byte upgrades never imply replacement of a live server or killing children.

Keep auth, credentials, trust, sessions/history, Herdr config/onboarding unless explicit key policy is approved, sockets/logs/layout/saved machines, project bindings and child artifacts host-owned. Use only secret references, never values in config/metadata/fixtures. The Unix API socket defaults to `~/.config/herdr/herdr.sock` (named-session sockets separate); selected source sets 0600, not a host audit or same-user sandbox. Permission tests touch only a separately authorized isolated runtime, never chmod/delete unmanaged trees or sockets.

## Compatibility caveats and gates

- Exact pi-subagents source emits `herdr:busy`; the selected official hook has a **missing receiver in the inspected selected official route; user-visible effects untested**. Pi's inspected event-bus/loader does not translate it. `report-metadata` is a distinct presentation path, not semantic `report-agent` authority. This is not a full-tree/custom-extension audit. Semantic idle must never be sole proof all children finished or peer-pane/destructive cleanup is safe.
- Matching `herdr:blocked` emitter/receiver exists, but overlap/ack/clear/session attribution needs tests. Official basic discovery/lifecycle/native restore, metadata, semantic busy, blocked overlay, shutdown and inspector/project panes are separate compatibility surfaces, not one all-or-nothing claim.
- The official hook has no explicit shutdown authority release or queued-report drain. **Pi core does track and remove event-bus subscriptions**, and pi-subagents has disposal/flush. Therefore no leaked listener/stale authority/broken cleanup is proven; ordering, socket drain and server-side authority outcomes need isolated tests.
- Official semantic reporting gates on TUI mode. Subagent metadata gates on `hasUI`, which RPC can satisfy; inherited-environment RPC metadata is not excluded by that gate. Test modes separately and explicitly accept a limitation or obtain approved upstream resolution where required.
- Record the exact binary, hook revision, Pi and subagent versions and run the auth-free compatibility matrix before enabling/promising each corresponding behavior. Missing/old/unreachable Herdr must remain local to optional UI actions; no child rerouting, competing lifecycle publisher, speculative shim or unreviewed pin update.

## Non-goals

No implementation in this research handoff. No repo Go module/daemon/service unit, custom subagent engine, remote agent launch, auto-start, wrapper service, adoption/handoff, model/provider gateway, GUI prerequisite, headless-to-pane migration, trust bypass, secret/auth/session management, public TCP service/port, browser dashboard, SSH/VPS/Dokploy/remote auto-install, Herdr-driven worktree cleanup, undocumented UI config, fallback launcher, compatibility wrappers or generic optional-dependency expansion.

## Open decisions and risks (not approvals)

1. Post-TASK-34 installation opt-in interface versus runtime optionality; do not register always-installed capabilities and call that opt-in.
2. Review the single full-stack composition policy; independent plain-Pi integration would need a genuine requirement before adding a second composition.
3. Selected-trio busy/blocked/shutdown/mode compatibility outcomes: deliberately accepted limitations versus approved upstream resolution/new reviewed pin; no source-only pass/failure inference.
4. Hook installer/file ownership and atomic activation; handling unmanaged conflicts without takeover by default.
5. Herdr user config versus narrowly managed keys/examples; version/manifest background-update policy and its reproducibility limits. No verified config include mechanism.
6. OS/libc/macOS quarantine/signing and WSL support evidence; unsupported prerequisites block rather than trigger apt/brew/sudo.
7. Installed client versus live server compatibility; human-only restart guidance, no implicit stop/handoff/child termination.
8. Independent verification and manual terminal evidence, including peer-pane trust/control/close, without real credentials or dangerous ambient extensions in ordinary verify.

## References

The attached Backlog document is the full sourced specification, containing exact source citations, pin/integrity matrix, ownership and dependency contract, compatibility surfaces, unchecked acceptance criteria and automated/manual platform matrix. Read it with TASK-34 before future execution. Original and recovered researcher artifact paths are provenance only; durable primary URLs and findings are included in the document.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 After TASK-34, graph and selection tests demonstrate that the existing `pi` and `pi-subagents` identities remain runnable/installable without Herdr; the proposed selected full-stack `herdr-pi` requires `pi`, `herdr` and `pi-subagents`, `herdr` requires only `foundation`, and existing Node/Pi/skills prerequisites remain. Packages register once, no cycles or speculative optional-dependency schema are introduced, and core stays domain-neutral. The installation opt-in mechanism is explicitly reviewed/documented rather than inferred from runtime optionality.
- [x] #2 Supported Linux x86_64, WSL-as-Linux x86_64 and macOS arm64 setup uses reviewed exact Herdr version URLs/SHA-256 through engine provisioning, with mismatch rejection before activation. Existing Pi/subagent exact versions and registry integrity remain unless a new pin is explicitly reviewed; hook bytes/revision are recorded. No sudo/OS package manager, unpinned installer, Node bootstrap, repo Go daemon, wrapper service or chezmoi public lifecycle entry is introduced.
- [ ] #3 Repeated scratch-home setup leaves matching binary/hook unchanged and detects drift or unmanaged same-name conflicts without overwriting user data absent explicit takeover approval. Install and verify honor the same target home/PI_CODING_AGENT_DIR. Fixtures preserve unrelated extensions/settings, Herdr config, dummy auth/trust/session files, role overrides and project bindings; no recursive exact-management of user trees occurs.
- [ ] #4 Normal setup/sync/verify demonstrably starts/stops/restarts no Herdr server, opens/adopts no pane or child, scans no live session, resolves no credentials and calls no model/vault API. Normal verification checks exact hook bytes/revision plus actual start/reload discovery/handlers using isolated trusted resources and synthetic events, not existence alone or ambient extensions. Network-denied/offline fixtures document that PI_OFFLINE is not a sandbox.
- [ ] #5 Official semantic-state reporter fixtures cover absent/partial/stale Herdr environment, inherited-environment RPC/JSON/print suppression, TUI pane/session identity, new/resume/fork/reload, settled versus low-level agent end, counted blocked overlap and socket failure/timeouts. Independently test pi-subagents metadata isolation by mode: its hasUI gate does not exclude RPC with inherited Herdr environment, so any gap requires an explicitly accepted limitation or approved upstream resolution before that behavior is promised.
- [ ] #6 Existing subagent, bg_wait, bundled skill and role override verification remains. Fixtures show absent/old/unreachable Herdr affects only optional inspector/project-pane actions without rerouting children or fallback launches. Document and test managed PATH, HERDR_BIN versus HERDR_BIN_PATH, and PI_SUBAGENT_PI_BINARY scope; standalone headless foreground/background operation is preserved.
- [ ] #7 Exact-trio fixtures cover current-session metadata restore/refresh/clear without raw task/goal leakage and the herdr:busy emitter with missing receiver in the inspected selected official route; user-visible effects remain untested until synthetic evidence and human TUI observation are recorded. Accept a documented limitation or explicitly approved upstream resolution/new reviewed pin before promising semantic async-busy behavior. No competing lifecycle publisher or speculative shim is added, and semantic idle alone never proves child completion or safe destructive cleanup.
- [ ] #8 Shutdown/exit/reload compatibility evidence distinguishes Pi core tracked event-bus cleanup and the subagent disposer/flush from the official hook lacking explicit authority release or queued socket-report drain. Test report races/drain, replacement/session identity and observed authority cleanup in separately authorized isolated runtime/TUI checks; record outcomes without inferring leaked listeners, stale authority or a pass from source absence. Required failures gate support pending approved upstream resolution or deliberately accepted limitation.
- [ ] #9 Inspector fixtures verify selected run/child identity, artifact/status reads and acknowledged control via existing subagent authority; closing an inspector never stops its child. Project-pane fixtures verify separate cwd/session/resource discovery, binding identity, stale/foreign binding rejection, explicit idle close guard and human trust requirement. Existing headless runs are never attached/moved/adopted; semantic idle alone cannot authorize peer-child destructive cleanup.
- [x] #10 Upgrade/offline verification tests leave live servers, sockets and children host-owned; docs distinguish installed binary, integration revision, Pi/subagent pins and runtime server version, report updater drift and give human-only restart guidance. Separately authorized isolated runtime tests check socket owner/mode without touching unmanaged sockets/trees. No public TCP service, SSH/remote auto-install, credential copying or broad config rewrite is added.
- [ ] #11 Before enabling or promising corresponding behavior, record the exact Herdr binary/integration revision/Pi/pi-subagents trio and results of the document compatibility matrix, including absent/no-server/headless/TUI/async/blocked/reload/inspector/project-pane cases. Relevant fast checks and TASK-34-final scratch-apply/verify harness pass on Linux/WSL and macOS arm64, with explicit human terminal evidence and accepted limitations; no generated state is committed. Platform libc/OS/quarantine unknowns must be resolved or clearly gate support, never silently trigger OS package installation.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. herdr package (requires foundation): provision.file pinned v0.9.0 binary (linux x86_64 + darwin arm64 URLs/SHA-256 in versions.json, independently re-hashed) to ~/.local/opt/herdr/bin/herdr mode 755; symlink .local/bin/herdr; verify = installed hash + --version match (non-starting). 2. herdr-pi composition package (requires pi, herdr, pi-subagents): owns ONLY the official hook bytes as a package asset deployed via chezmoi file recipe to .pi/agent/extensions/herdr-agent-state.ts (private; fail-closed on unmanaged conflicts); verify = exact bytes + HERDR_INTEGRATION_VERSION marker + isolated Pi loader discovery (HERDR_ENV unset => inert, PI_OFFLINE=1, no sockets/models). 3. Catalog registration once each; graph/parity tests updated (package counts, dependency order, scratch provisioning like go). 4. Independent hashing of both release binaries + hook asset; record digests. 5. Docs: capabilities.md graph + package list, tools.md inventory, new docs/herdr.md with the compatibility-gate table (verified vs documented-limitation rows per spec doc-1) and human-only runtime guidance. 6. Opt-in decision documented: standard registration on supported hosts (owner-directed); runtime optionality preserved (pi/subagents never require herdr; hook inert without HERDR_ENV). 7. Checks: suite battery + scratch applies; real-host apply/sync/verify. Compatibility matrices beyond static+discovery scope (AC 5-9 semantics) recorded as explicit documented limitations per the spec gate table.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
MILESTONE 1 SHIPPED (packages live on real host): herdr 0.9.0 pinned binary (provision.file, ~/.local/opt/herdr/bin/herdr + .local/bin/herdr link; linux x86_64 + darwin arm64 URLs/SHA-256 in versions.json, both digests + hook independently re-hashed and matching publisher metadata) and herdr-pi composition (requires pi+herdr+pi-subagents; exact official v0.9.0 hook bytes, integration revision 8, deployed as a private-owning file recipe fail-closed on unmanaged conflicts; verify = byte equality + revision marker + isolated Pi loader discovery with HERDR_ENV deleted, scratch agent dir, PI_OFFLINE-safe, no sockets/servers/credentials). bootstrap.pins regenerated after versions.json change. Tests: capabilities (15 packages, graph order, requires, herdr-never-gates-pi assertions), package-provision (count), backend-render (hook byte parity + herdr symlink); full battery green except pre-existing TASK-37 cascade in check.test. Real host: apply+setup deployed binary/link/hook, verify complete (herdr + herdr-pi green, 11/0 elsewhere). Opt-in decision (AC1): standard registration on supported hosts per owner direction; runtime optionality proven by graph tests (pi/pi-subagents never require herdr). Compatibility gates recorded in docs/herdr.md (busy-receiver gap, shutdown/reload, RPC isolation explicitly NOT promised; semantic-idle warning). REMAINING (ACs 3-9, 11 open): PI_CODING_AGENT_DIR parity in hook targeting, synthetic event fixtures (busy/blocked/shutdown races/mode isolation), inspector/project-pane fixtures, WSL+macOS arm64 CI/human acceptance. AGENTS.md change-rule coverage: contribution+catalog+tests+docs done.
<!-- SECTION:NOTES:END -->
