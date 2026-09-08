---
id: doc-1
title: 'Herdr + Pi + pi-subagents: engine-authoritative capability specification'
type: specification
created_date: '2026-09-08 23:47'
updated_date: '2026-09-08 23:47'
---
# Herdr + Pi + pi-subagents: engine-authoritative capability specification

## Summary

Herdr is a terminal workspace/runtime with a persistent background server—not a desktop GUI and not a replacement subagent engine. Preserve `pi` and `pi-subagents`; propose a separately provisioned `herdr` and an optional composition capability owning the official Pi integration and cross-package verification. The installed subagent package already implements both directions: it publishes pane metadata and can request Herdr inspector/project panes; important lifecycle compatibility gaps remain and must not be represented as verified functionality.

Status: future-work research/design proposal only; no implementation approved or started. TASK-34 is the blocking, user-approved engine-authoritative architectural direction; the Herdr-specific choices below remain proposals or explicit open decisions. This document and its To Do task were created through Backlog CLI in an isolated clone; **canonically imported through Backlog CLI after parent review**. No runtime compatibility verdict is claimed.

Research snapshot: `/tmp/workstation-herdr-spec.jQkeOU`, branch `research/herdr-pi-spec`, base commit `e809f40b5aef82e395a65dd101db00a5d0e64747`. Only new Backlog task/document files are project changes. No implementation, installation, agent/service launch, secret access, staging, commit or publication is part of this handoff.

Evidence provenance: the source inspection and installed-package observations below are inherited from the original researcher, not repeated runtime tests by the task writer. The complete original report and recovered correction report were read; corrections are integrated here and override their older shorthand. Original artifact: `/root/.pi/agent/sessions/--root-lazyvim--/subagent-artifacts/outputs/ef2a7f4b-7bbc-4a22-82a9-f43dadaf25df/herdr/research-and-spec.md`. Recovery artifact: `/root/.pi/agent/sessions/--root-lazyvim--/subagent-artifacts/outputs/7891bfa3-f1ea-496d-a632-17872a5630dd/herdr/research-recovered.md`. These are provenance paths, not prerequisites on a future implementation host; the durable findings and primary citations are preserved below.

## Evidence basis and version scope

The original researcher read the required snapshot AGENTS, index/capability docs, explicit catalog, contribution contract, provision primitives, Pi/subagent package implementations and verifier, versions manifest, and **all** of tracked `backlog/tasks/task-34 - Make-the-workstation-capabilities-engine-authoritative-over-chezmoi.md`. Read installed pi-subagents observability, workflows, configuration, extension-api and execution-controls documents completely, plus manifest, public project-pane export, project-pane implementation and Herdr client. Read installed Pi README, packages, SDK and extensions documents completely (including continuation reads), manifest and SDK extension example.

Installed manifests and registry `latest` agree: Pi **0.85.1**, pi-subagents **0.66.0**. Registry integrity matches the snapshot pins. Registry gitHeads: Pi `d981de1229ef899957bbe968bc8dcda02a21f477`; subagents `0fc0eebb9604970c506708b7508d6aa38921fde2`. The latter's upstream extension-api document was fetched completely and agrees with installed Herdr integration documentation. Herdr GitHub latest stable was **v0.9.0**, published **2026-09-07**, `prerelease:false`, `immutable:true`; its bundled Pi extension identifies itself as **integration version 8**. Retrieved master has the same relevant extension behavior, but master is not a proposed provisioning pin.

Three original `source_check` calls (optional integration, release/pins, and lifecycle discrepancy) and the bounded recovery check (0.30) returned **unclear**, not affirmative validation. Therefore conclusions below rely on inspected primary passages/source, not those automated verdicts. Binaries were not downloaded or independently hashed; GitHub asset digests are publisher metadata, not an independent supply-chain audit.

## 1. What Herdr provides and its Pi integration

1. **Claim:** Herdr owns terminal panes and client/server persistence; Pi runs inside a pane. **Support:** direct evidence; **confidence:** high. [Persistence](https://herdr.dev/docs/persistence-remote/), opening: “Herdr keeps panes running in a background server. Your terminal client can detach and reconnect later.” Detach leaves agents running; server stop ends the session/panes. [v0.9.0 release](https://github.com/herdrdev/herdr/releases/tag/v0.9.0), Removed: “Removed the single-process `--no-session` mode. All terminal UI launches now attach to a background server.” No X11/Wayland desktop is required by this documented terminal interface. Native desktop clipboard/image features are ancillary, not a reason to make headless Pi depend on Herdr.

2. **Claim:** Official Pi integration installs one bundled TypeScript extension, not an npm Herdr package or new model provider. **Support:** direct evidence; **confidence:** high. [Integrations, Pi](https://herdr.dev/docs/integrations/#pi): `herdr integration install pi` writes `~/.pi/agent/extensions/herdr-agent-state.ts`; with `PI_CODING_AGENT_DIR`, destination is `$PI_CODING_AGENT_DIR/extensions/herdr-agent-state.ts`. “Herdr creates the extensions directory when the Pi agent directory already exists. Uninstall removes only that extension file.” [v0.9.0 targets.rs](https://raw.githubusercontent.com/herdrdev/herdr/v0.9.0/src/integration/targets.rs), `install_pi`: `ensure_extension_dir`, then `fs::write(&path, PI_EXTENSION_ASSET)`. It overwrites the named file; it is not a merge operation. Installation must follow Pi directory initialization and protect an unrelated pre-existing file.

3. **Claim:** Actual v0.9.0 Pi transport is direct local socket JSONL; lifecycle authority and session identity are distinct. **Support:** direct source evidence; **confidence:** high. [Bundled extension](https://raw.githubusercontent.com/herdrdev/herdr/v0.9.0/src/integration/assets/pi/herdr-agent-state.ts): `source = "herdr:pi"`; `enabled()` requires `HERDR_ENV === "1"`, socket and pane ID; `net.createConnection(socketEndpoint)` writes `${JSON.stringify(request)}\n`. Methods are `pane.report_agent_session` and `pane.report_agent`; it sends increasing `seq`, pane ID, agent `pi`, semantic state, optional message, and prefers absolute session-file path over session ID. It does not upload the session transcript. Requests retry with 500ms then 1500ms attempt limits; receiving any data is treated as delivery, not parsed application acceptance. [Socket API](https://herdr.dev/docs/socket-api/), transport: “Herdr uses newline-delimited JSON over a local socket. On Unix, that socket is a Unix domain socket.” This is **not Pi's stdin/stdout RPC protocol**.

4. **Claim:** The official semantic-state reporter is TUI-only even if Herdr environment leaks into a headless child; this must not be generalized to the pi-subagents metadata bridge, which checks `hasUI` rather than mode (see compatibility gate below). **Support:** direct source evidence; **confidence:** high. Bundled extension `session_start`: `if (ctx?.mode !== "tui") return;`, with comment “RPC still reports hasUI=true, so mode is the reliable gate.” It uses `agent_start`, `agent_settled` with `ctx.isIdle()`, and `herdr:blocked`. [Pi extensions at pinned gitHead](https://github.com/earendil-works/pi/blob/d981de1229ef899957bbe968bc8dcda02a21f477/packages/coding-agent/docs/extensions.md), Agent Events: “Use `agent_settled` for status integrations that need to know Pi will not continue running automatically.” Mere loader discovery is therefore not proof of lifecycle reporting.

5. **Claim:** Herdr pane identity/environment does not imply child orchestration/context ownership. **Support:** direct evidence plus interpretation; **confidence:** high. [Integrations, Integrate your own agent](https://herdr.dev/docs/integrations/): pane processes inherit `HERDR_ENV`, `HERDR_PANE_ID`, `HERDR_BIN_PATH`, `HERDR_SOCKET_PATH`. [Socket API](https://herdr.dev/docs/socket-api/), process-launching methods: launch-specific `env` applies to newly launched processes; Herdr injects workspace/tab/pane/socket environment and its managed variables win conflicts. Pi itself loads cwd-scoped instructions/resources and stores its sessions. No evidence supports copying model credentials or parent conversation context through Herdr metadata. Native restore uses reported Pi references and supported agent resume launching, not adoption of arbitrary external processes.

## 2. Bidirectional Herdr / pi-subagents relationship

Primary pinned reference for this section: [extension-api, Herdr integration](https://github.com/nicobailon/pi-subagents/blob/0fc0eebb9604970c506708b7508d6aa38921fde2/docs/extension-api.md#herdr-integration); installed matching documents were inspected directly.

1. **Subagents → Herdr metadata:** “When Pi runs inside Herdr, pi-subagents automatically reports active async-run counts through Herdr pane metadata.” Requires `HERDR_ENV=1` and `HERDR_PANE_ID`; outside Herdr the documented bridge registers no listeners/timers. It restores current-session runs after reload/resume, refreshes active metadata and clears it on completion/shutdown. Only the owning Pi session publishes its pane. Explicit bounded workflow labels, agent names/counts and attention indicators populate summary/title suffixes; “Raw task and goal prompts never enter Herdr metadata.” This is native subagent functionality, not a new workstation-owned bridge. **Support:** direct documentation; **confidence:** high for documented contract, runtime behavior not executed.

2. **Subagents → Herdr inspectors:** Herdr **0.7.5+** is documented for `inspector.open/status/close`. “The inspector is a raw dashboard pane, not the child session and not a literal attach.” It reads lifecycle/status/output/mission artifacts; steer/stop go through the existing pi-subagents control inbox. “Closing it never stops the run.” [Observability](https://github.com/nicobailon/pi-subagents/blob/0fc0eebb9604970c506708b7508d6aa38921fde2/docs/observability.md), Fleet inspector: `/subagents-fleet`, `Ctrl+Alt+F`, selected-child `H`/Enter; textual fallback without a TUI. **Support:** direct documentation; **confidence:** high. Inspector input is real run control, unlike metadata; closing an inspector must not be confused with stopping work.

3. **Subagents → Herdr → separate Pi project session:** `project.open` requests a pane rooted at explicit cwd. “The parent session keeps coordination authority, but it does not own or control the subagents inside the peer pane. Existing headless runs are not moved into the pane.” Binding: `<projectRoot>/.pi/subagents/project-panes/herdr.json`. [Installed-equivalent project-pane source](https://github.com/nicobailon/pi-subagents/blob/0fc0eebb9604970c506708b7508d6aa38921fde2/src/inspectors/herdr/project-panes.ts): `pane split --current --direction right --cwd ...`, then `pane run`; stores project/pane/version/command/startup-message pointer. These records can contain user instructions and are host/project runtime state, not managed dotfiles. Public consumers use `pi-subagents/project-panes`, API version 1, never internal imports. Close verifies pane/canonical cwd and requires explicitly idle status; `requireIdle:false` cannot weaken it. Trust is reported as `human-verification-required`. **Support:** direct code/doc evidence; **confidence:** high.

4. **Herdr → Pi/subagents:** Herdr launches/hosts the owning Pi terminal session and observes its integration reports. A user selects the subagent inspector through the existing Pi Fleet surface; the inspector provides bounded control via subagents' existing authority, not a Herdr subagent engine. An independent Herdr project pane's new Pi instance discovers the target project's configuration/resources under normal Pi trust rules. No evidence establishes Herdr automatically enumerates/adopts every existing standalone headless child or directly implements pi-subagents event-bus RPC. **Support:** interpretation of explicit ownership contracts; **confidence:** high.

5. **Availability detection is real, but narrower than compatibility proof.** [client.ts](https://github.com/nicobailon/pi-subagents/blob/0fc0eebb9604970c506708b7508d6aa38921fde2/src/inspectors/herdr/client.ts), `createHerdrClient`: executable is `options.bin ?? process.env.HERDR_BIN ?? "herdr"`, **not `HERDR_BIN_PATH`**; spawn uses `shell:false`, inherited environment. `detectHerdr` runs `--version` with 3-second timeout and requires version >=0.7.5; missing executable produces `HERDR_UNAVAILABLE`, old version `HERDR_UNSUPPORTED_VERSION`. Version success does not prove server presence, matching server feature support, socket access or valid current pane. [Configuration](https://github.com/nicobailon/pi-subagents/blob/0fc0eebb9604970c506708b7508d6aa38921fde2/docs/configuration.md#pi_subagent_pi_binary): `PI_SUBAGENT_PI_BINARY` controls project-pane/model-probe Pi executable, **not child execution**. Keep managed binaries on PATH; do not invent a global HERDR environment bootstrap.

6. **Run engine remains pi-subagents.** [Observability, Foreground runs](https://github.com/nicobailon/pi-subagents/blob/0fc0eebb9604970c506708b7508d6aa38921fde2/docs/observability.md): “A foreground child is a pi session created inside the parent Pi process, not a second `pi` process”; background child lives inside the detached runner process. Configuration says background children require installed Pi npm package modules, not only a standalone binary. Keep existing managed Node/Pi npm installation. Event bus is in-process only; do not repurpose it as cross-process transport. **Support:** direct documentation; **confidence:** high.

### Material compatibility gaps — recovered exact-source qualifications

The following source-backed findings supersede the original report's broader busy/shutdown/headless shorthand. Confidence concerns inspected source, not an executed compatibility test.

### 1. Actual busy and blocked emitters

**Claim:** pi-subagents 0.66.0 emits `herdr:busy`; the statement is now supported by code, not only documentation. **Support:** direct evidence. **Confidence:** high for source behavior, no runtime test.

Source at its published gitHead:
- [herdr-status.ts, lines 245–281](https://github.com/nicobailon/pi-subagents/blob/0fc0eebb9604970c506708b7508d6aa38921fde2/src/integrations/herdr-status.ts#L245-L281), `syncBusy` and `syncBlocked`.
- [Raw exact source](https://raw.githubusercontent.com/nicobailon/pi-subagents/0fc0eebb9604970c506708b7508d6aa38921fde2/src/integrations/herdr-status.ts).

The installed file was read completely and its line-245 slice was separately read to establish line references. Relevant literal passages:

- `syncBusy`: `if (!enabled || !rootSession || disposed) return;`
- Active work: `options.events.emit("herdr:busy", { active: true, label: text });`
- Clearing/changing work: `options.events.emit("herdr:busy", { active: false });`
- `syncBlocked`: `options.events.emit("herdr:blocked", { active: true, label: nextLabel });` and matching `active: false` events.

The same file's `publish` sends **CLI `pane report-metadata`**, source `pi-subagents:herdr`, with `--applies-to-source herdr:pi`, labels for idle/done/working, summary/title suffix, TTL and sequence. This is a separate presentation path, not an alternate semantic `report-agent` busy publisher. `replaceRuns` and the async-start/complete subscriptions invoke `syncBusy`; attention control invokes `syncBlocked`.

### 2. Registration and dispatch path; alternate paths examined

**Claim:** The inspected built-in route does not translate the busy event into a different event or transport. **Support:** direct source plus bounded interpretation. **Confidence:** high for inspected functions; not a repository-wide proof about every possible third-party extension.

- [pi-subagents extension registration, lines 830–889](https://github.com/nicobailon/pi-subagents/blob/0fc0eebb9604970c506708b7508d6aa38921fde2/src/extension/index.ts#L830-L889): `registerHerdrStatusBridge({ events: pi.events, getRuns: activeHerdrRuns, ... })`; `runHerdr` uses `pi.exec(process.env.HERDR_BIN || "herdr", [...args], { timeout: 5_000 })`. The bridge's disposer is put into `eventUnsubscribes`. File tail `session_start` calls `herdrStatusBridge.sessionStarted({ hasUI: ctx.hasUI === true, runs: activeHerdrRuns() })`; `session_shutdown` calls runtime cleanup and awaits bridge flush. [Exact source](https://raw.githubusercontent.com/nicobailon/pi-subagents/0fc0eebb9604970c506708b7508d6aa38921fde2/src/extension/index.ts).
- [Pi 0.85.1 extension loader](https://github.com/earendil-works/pi/blob/d981de1229ef899957bbe968bc8dcda02a21f477/packages/coding-agent/src/core/extensions/loader.ts), `createExtensionAPI`: `events.emit` directly calls `eventBus.emit(channel, data)`; `events.on` registers `eventBus.on(channel, handler)` with tracked cleanup. In contrast `pi.on(event, handler)` writes to `extension.handlers`. No busy-to-blocked or busy-to-agent lifecycle alias appears in these dispatch functions. `loadExtensionsInternal` supplies the shared resolved event bus to loaded factories.
- [Pi event-bus.ts, lines 1–33](https://github.com/earendil-works/pi/blob/d981de1229ef899957bbe968bc8dcda02a21f477/packages/coding-agent/src/core/event-bus.ts#L1-L33): a Node `EventEmitter`; `emit` calls `emitter.emit(channel, data)`, `on` calls `emitter.on(channel, safeHandler)`. It has no wildcard semantic mapping or Herdr transport. Raw source was fetched to avoid readable-extraction corruption of TypeScript `data:` parameters.
- [Herdr v0.9.0 entire bundled Pi extension](https://github.com/herdrdev/herdr/blob/v0.9.0/src/integration/assets/pi/herdr-agent-state.ts), factory/event-registration tail: only `pi.events.on("herdr:blocked", ...)`, `pi.on("session_start", ...)`, `pi.on("agent_start", ...)`, and `pi.on("agent_settled", ...)` are registered. Header: `HERDR_INTEGRATION_VERSION=8`. It imports only `node:net`; the complete asset contains no imported alternate hook, busy listener, event-name mapping, `session_shutdown` or UI-prompt hook. [Raw exact asset](https://raw.githubusercontent.com/herdrdev/herdr/v0.9.0/src/integration/assets/pi/herdr-agent-state.ts).

**Bounded conclusion:** no `herdr:busy` receiver exists in this selected official Pi asset, and the inspected Pi event-bus/loader path does not synthesize one. The alternative metadata path can describe active work without changing semantic state. This does **not** prove that every possible host/custom extension lacks a listener, or establish the exact UI state a real host will show. No full-tree source search/runtime instrumentation was performed during recovery; the conclusion intentionally concerns the inspected official route only.

### 3. Important shutdown qualification: core does provide listener cleanup

**Claim:** Absence of a shutdown handler in Herdr's Pi asset does not mean its event-bus listener necessarily leaks after reload. **Support:** direct evidence plus interpretation. **Confidence:** high for available cleanup implementation; ordering/runtime outcome untested.

[Pi loader at the pinned gitHead](https://github.com/earendil-works/pi/blob/d981de1229ef899957bbe968bc8dcda02a21f477/packages/coding-agent/src/core/extensions/loader.ts), `createExtensionRuntime` tracks `eventBusUnsubscribers`; its invalidation path executes `for (const unsubscribe of eventBusUnsubscribers) unsubscribe();` and clears the set. `createExtensionAPI.events.on` uses `runtime.trackEventBusSubscription(...)`. That is an **alternate core-owned subscription-cleanup mechanism** and must be acknowledged in the task.

The narrower unresolved issue is that the bundled asset does not explicitly issue an authority release or manage its own queued socket-report completion at shutdown. Server-side process/authority cleanup and Pi lifecycle ordering may affect observed outcomes. Keep shutdown/exit/reload behavior a future compatibility gate; do not assert proven stale authority, leaked listeners or broken cleanup.

Separately, pi-subagents' own `dispose` clears attention and runs, lowers busy, refreshes/clears metadata, unsubscribes listeners, and becomes disposed; main shutdown flushes pending bridge reports. These are **not** the same as the official Pi asset explicitly releasing `herdr:pi` lifecycle authority.

### 4. Additional narrowly discovered caveat: RPC mode gates differ

**Claim:** Do not generalize the official hook's TUI-only guard to the subagent metadata bridge. **Support:** direct evidence. **Confidence:** high for source; runtime result untested.

Herdr official asset's `session_start` requires `ctx.mode === "tui"` and comments that RPC can have `hasUI=true`. In contrast the inspected pi-subagents registration forwards `ctx.hasUI === true`, and bridge `sessionStarted` checks `hasUI`, not mode. Thus RPC with inherited Herdr environment is **not excluded by that bridge's own gate**. Whether a particular runtime reaches this route with active runs is not established here.

Correct original report AC5 interpretation: **TUI-only suppression is a source-backed claim for the official semantic-state reporter.** For pi-subagents metadata, RPC/headless inherited-environment isolation must be explicitly tested and any required behavior accepted as a documented limitation or resolved upstream; it cannot be assumed already satisfied. Do not add a research-time shim, change the package, or bump dependencies.

### Compatibility gate for future implementation

Separate these assertions rather than marking the whole integration supported/unsupported:

| Surface | Source-backed position | Required future evidence |
|---|---|---|
| Basic official Pi integration | Installable bundled v8 hook; gated TUI lifecycle/session reports over Herdr local socket | Discovery, correct identity, state transitions and native restore with selected exact trio |
| Subagent metadata | Native bridge sends labels/counts via `report-metadata` | Active/reloaded/completed projections, no raw task leakage, mode isolation |
| Async busy semantic state | `herdr:busy` emitter exists; selected official receiver absent | Synthetic compatibility test plus human TUI observation; upstream resolution or explicit accepted limitation before promise |
| Async blocked overlay | Matching emitter/receiver exist | Counted overlap, attention acknowledge/clear, reload ordering and correct pane/session |
| Shutdown/reload | Subagent disposer and Pi core listener cleanup exist; official hook has no explicit authority release | Observe exit authority, report drain/races, replacement/session identity and cleanup; no inferred failure/pass |
| Inspectors/project panes | Existing separate dashboard/peer-pane machinery, not child adoption | Optional availability and control/close ownership tests; human trust/focus tests |

The compatibility description is **“missing receiver in inspected selected official route; user-visible effects untested.”** A semantic-idle pane must not be accepted as sole proof that all subagent work ended or that peer-pane close/destructive cleanup is safe. This is conservative design policy, not an observed bug reproduction.

Future AC: record exact Herdr binary, integration revision, Pi and pi-subagents versions; run the isolated/auth-free compatibility matrix before enabling or promising the corresponding behavior. If a required behavior fails, obtain an explicitly approved upstream resolution/new reviewed pin or document a deliberately accepted limitation. No competing lifecycle publisher, speculative workaround or silent pin bump.

- Herdr docs list Pi integration version **2** as minimum for native restore. That is not the latest extension version (v0.9.0 bundles **8**) and not a Pi CLI minimum. [version.rs](https://raw.githubusercontent.com/herdrdev/herdr/v0.9.0/src/integration/version.rs) enforces only Kimi minimum; no Pi minimum is supplied. Pin/test the actual trio rather than inventing a Pi compatibility floor.

## 3. Platform/install matrix and integrity

Recommended candidate pin: **Herdr 0.9.0**, subject to lifecycle caveat decision and tests. Direct evidence: [release API](https://api.github.com/repos/herdrdev/herdr/releases/latest), asset `name`, `browser_download_url`, `digest`; [install, Download manually](https://herdr.dev/docs/install/).

| Repository host | Release asset and immutable version URL | Published SHA-256 | Status |
|---|---|---|---|
| Linux x86_64 | https://github.com/herdrdev/herdr/releases/download/v0.9.0/herdr-linux-x86_64 | `4fa1a01158dd8043da92d31b270780b0dcc10603038d9b61cac4d81ab63fb71f` | Official binary identified in publisher metadata; no independent hash or execution test |
| WSL-as-Linux x86_64 | Same Linux asset | Same checksum | Repository mapping proposal; release notes mention WSL remote clipboard fix, not full distro/runtime certification |
| macOS arm64 | https://github.com/herdrdev/herdr/releases/download/v0.9.0/herdr-macos-aarch64 | `32b53df09872628059c789a69f02a6b8e29e14ddf26711421f3463f70c1aef17` | Official Apple Silicon binary identified in publisher metadata; no independent hash or execution test |

Retain the snapshot's exact npm pins/integrities (read from `workstation/versions.json`; not permission to bump):

| Component | Version / source revision | Registry integrity / compatibility status |
|---|---|---|
| Pi (`@earendil-works/pi-coding-agent`) | `0.85.1`; gitHead `d981de1229ef899957bbe968bc8dcda02a21f477` | `sha512-FGRN+OHbWaefBPGaTggAdLjrIHW+s2PzLyglz/5dfLzb9of7uuXMXYC0fJIeZTw+shS32o2cuQ9jF7YSDuL/oQ==`; existing pin, exact trio runtime untested |
| `pi-subagents` | `0.66.0`; gitHead `0fc0eebb9604970c506708b7508d6aa38921fde2` | `sha512-PfvGutk0QJ2Ps0lC/a9L5T9n3RCo7w7Nt0hXg08cbj9uyUEwdrWRCYEpfZ2jMTC/1sOUpnCrVZF/669Qeek0lw==`; existing pin, exact trio runtime untested |
| Bundled official Pi hook | Herdr `v0.9.0`, `HERDR_INTEGRATION_VERSION=8` | Expected-byte hash not computed; must obtain/review and verify before activation |
| Other architectures / native Windows | No additional selection proposed | Explicitly unsupported by this proposal until separately reviewed; WSL maps to Linux x86_64 |

Proposed engine provisioning uses `context.provision.file` for the platform's binary, user-local executable destination (proposed `~/.local/bin/herdr`), SHA-256 and executable mode. Do not run `curl | sh`, Homebrew, mise, Nix or `herdr update` for a workstation-managed tool. Those are upstream alternatives, not approved repository dependencies. No sudo/system package manager is needed by the documented manual binary installation; minimum OS/libc versions and all dynamic-library prerequisites were **not verified**. Missing runtime dependencies must be a decision/blocker, never silently installed through apt/brew/sudo.

Bootstrap: pinned Neovim remains engine bootstrap/runtime; Herdr is a post-bootstrap capability, not a bootstrap prerequisite. Pi 0.85.1 declares Node `>=22.19.0`; managed installed Node 24.19.0 satisfies it. Herdr native binary needs no managed Node for itself; Pi extension and pi-subagents use existing managed Node/Pi. No Rust build toolchain or Go service module is proposed. Optional clipboard helpers and SSH remote setup are not installation prerequisites for the local integration and are out of scope.

Record Herdr pin/checksums in engine-owned `workstation/versions.json`; retain existing exact Pi/subagent versions/integrities. Pin the bundled integration's version and expected bytes/hash in owning package metadata or tests. This research did not compute an extension hash; implementation must obtain it from the selected release source/bundle and verify equality. Published binary SHA validation must happen before activation. Upgrades update binary, bundled integration and compatibility expectations together; running old servers remain host-owned and can differ from the newly installed client.

## 4. Proposed capability architecture (proposal, not approved implementation)

Required arrows mean prerequisite → dependent:

```text
foundation → node → pi → pi-skills
                        pi + pi-skills → pi-subagents
foundation → herdr
pi + herdr + pi-subagents → herdr-pi   [optional composition selection]
```

- Preserve **`pi`** ownership: exact npm CLI, managed Node environment, version/integrity verification.
- Preserve **`pi-subagents`** ownership: exact extension package, tools/skills/roles, run lifecycle, artifacts, existing optional Herdr metadata/inspector/project-pane functionality. It must **not** require `herdr` or `herdr-pi`.
- New **`herdr`**: binary provisioning and static/local verification; no dependency on Pi, Node or a graphical display. No daemon manager implementation: Herdr's own bundled server is runtime behavior when a human launches it. No auto-start service.
- Proposed **`herdr-pi`** composition: requires `herdr`, `pi`, **and `pi-subagents` for this requested full-stack composition**; owns deployment/verification of the official Pi hook and cross-package compatibility tests/documentation. This explicit subagent prerequisite expresses the user's bidirectional relationship without cyclic core dependencies. The official hook itself does not technically require subagents; requiring them here is a chosen composition contract, not an upstream claim.
- If independent plain-Pi integration selection is a real requirement, use `herdr-pi` requiring only `herdr,pi` and a second thin `herdr-pi-subagents` composition requiring `herdr-pi,pi-subagents`. **Do not add the extra package without that requirement.** Prefer one full-stack composition now; keep installed subagents' native bridge, not a redundant workstation TypeScript bridge.
- OPTIONAL means headless Pi/subagents remain selectable/runnable without these packages, and Herdr-specific actions fail only locally when unavailable. The current contract has no optional dependency field; do not invent one, nor add externals/blueprint schema. Register factories explicitly once in catalog, core remains domain-neutral.
- **Unresolved selection detail:** the snapshot ordered catalog/contract does not by itself establish a user opt-in package-selection API. TASK-34 completion must be inspected before choosing how a composition is enabled/omitted. Do not silently register an always-installed package and call installation optional. Runtime optionality and workstation installation selection are distinct. A minimal explicit composition selection at the existing composition root is preferable to speculative generic-core extension; exact interface needs review.

TASK-34 supersedes snapshot docs and skill prose saying chezmoi is public apply authority or that setup only configures post-provision host state. Implement only after its engine-authoritative cutover: workstation public apply/update/setup/sync/verify; packages provision from setup, chezmoi subordinate pure home state. No compatibility wrappers and no parallel work against TASK-34's evolving main worktree.

## 5. Lifecycle, configuration and security responsibilities

### Lifecycle ownership and non-starting boundary

| Owner | Setup | Sync | Normal verify |
|---|---|---|---|
| `pi` (existing) | Existing exact npm CLI with managed Node | Existing ownership retained | Exact CLI/package version and integrity; no model/auth health probe |
| `pi-subagents` (existing) | Existing exact extension package and role/skill policy | No new runtime-state reconciliation | Preserve lock/discovery/tools/skills/role checks, isolated from ambient user resources |
| `herdr` (proposed) | Engine-owned pinned native binary provisioning | No initial handler | Static/hash/version checks only after confirming commands are non-starting |
| `herdr-pi` (proposed opt-in composition) | Only selected official hook file; ownership/idempotence checks | No initial handler | Isolated hook discovery and synthetic compatibility fixtures; explicit limitations |
| Human / upstream runtime | Human launches/reattaches Herdr; Herdr owns bundled server, PTYs and sockets; Pi owns sessions; subagents owns children/control/artifacts | Host-owned mutable state | Separately approved isolated runtime/TUI checks, not ordinary lifecycle verification |

No setup, sync or normal verify may start, stop, adopt or restart a Herdr server; open a pane; invoke model/vault APIs; resolve credentials; or scan live sessions. Runtime launch/reattach and intentional stop are host-owned. Detach is not stop, and installing newer bytes must not imply live-server replacement or termination of children.

### Setup

- `herdr`: select supported architecture; provision pinned binary atomically using engine primitives; never start/stop/attach a server or change channels. Do not infer process health from file presence.
- `herdr-pi`: ensure effective Pi agent directory exists after prerequisites. Manage **only** the official extension file. Preferred route: selected pinned binary's `integration install pi`, with preflight ownership/hash conflict checks and skip-if-identical; inspect installer non-service behavior before implementation use. Upstream uses direct `fs::write`, so package must decide safe staging/atomic activation if required. Alternative: checksum-pinned official source file via engine `provision.file`; choose one owner, never both engine and chezmoi for the same file. No new npm Herdr integration package is needed.
- Reject/preserve an unmanaged conflicting file unless user explicitly authorizes takeover. Version markers alone are insufficient to prove unchanged bytes. Do not recursively exact-manage `~/.pi/agent`, `extensions`, `~/.config/herdr` or project `.pi`.
- Respect the same target home and `PI_CODING_AGENT_DIR` across install and verify. Global Pi/subagent settings remain their existing owner; preserve unrelated packages and role overrides.

### Sync

No initial sync handler needed: runtime sessions, pane layout, missions, histories, authentication, trust and model state are host-owned. Sync must not launch agents, create inspectors/project panes, restart servers, restore user sessions automatically, resolve secret refs, or rewrite mutable remote-machine definitions.

### Configuration ownership

[Configuration](https://herdr.dev/docs/configuration/): Linux/macOS `~/.config/herdr/config.toml`; app can write onboarding/settings. Prefer **no mandatory Herdr config rewrite** for baseline integration. For reproducibility/offline tests, use isolated config with documented `update.version_check=false` and `update.manifest_check=false` ([config reference, Updates](https://herdr.dev/docs/config-reference/)); runtime can otherwise fetch detection-manifest changes outside the binary pin. Decide explicit managed-key merge versus user-owned example before deploying persistent policy. No verified config include mechanism was found; do not assume one. Optional sidebar recipe uses actual `ui.sidebar.agents.rows` containing `state_text` or `$summary`, not guessed UI paths. Do not force preferred Fleet placement/keybindings or overwrite user config for visual taste.

Generic repo state: pins, package definitions/verifiers, optional agreed non-secret config, usage/troubleshooting docs. Host-owned: Pi auth/trust/models credentials/session files, Herdr sockets/logs/layout/session state and saved machines, project-pane bindings/root indexes, child artifacts and missions. Secrets only through existing refs; do not copy values into Herdr config, metadata, reports or fixtures.

### Exposure and permissions

[Socket API](https://herdr.dev/docs/socket-api/): default `~/.config/herdr/herdr.sock`; named sessions `~/.config/herdr/sessions/<name>/herdr.sock`; explicit CLI session, `HERDR_SOCKET_PATH`, `HERDR_SESSION`, default determine resolution. [v0.9.0 API server](https://raw.githubusercontent.com/herdrdev/herdr/v0.9.0/src/api/server.rs), `SOCKET_PERMISSION_MODE = 0o600`; startup binds then restricts socket permissions. [ipc.rs](https://raw.githubusercontent.com/herdrdev/herdr/v0.9.0/src/ipc.rs) sets Unix file mode. **Direct evidence, high confidence for source behavior; not a host audit.** The socket can inspect terminal text and send input/launch/close processes. It is not a sandbox or authorization boundary between malicious same-user extensions; inherited environment requires careful isolation. Future permission tests may inspect owner/mode only on their own separately authorized isolated runtime, never chmod/delete unmanaged sockets or trees. No TCP listener, public port, SSH tunnel, browser dashboard, Dokploy or VPS infrastructure is required/proposed. No blanket claim about all runtime files having private permissions: verify those needed, do not chmod unmanaged trees.

Herdr detach differs from stop. Upgrades must not implicitly stop live servers/children. v0.9.0 supports compatible old servers after client updates, so static installed-version verification and live server compatibility are separate. Do not enable experimental handoff or remote auto-install through workstation lifecycle.

## 6. Testable acceptance criteria and verification matrix

Future implementation acceptance criteria (all unchecked intent, not evidence of completion):

- [ ] 1. After TASK-34, graph and selection tests demonstrate that the existing `pi` and `pi-subagents` identities remain runnable/installable without Herdr; the proposed selected full-stack `herdr-pi` requires `pi`, `herdr` and `pi-subagents`, `herdr` requires only `foundation`, and existing Node/Pi/skills prerequisites remain. Packages register once, no cycles or speculative optional-dependency schema are introduced, and core stays domain-neutral. The installation opt-in mechanism is explicitly reviewed/documented rather than inferred from runtime optionality.
- [ ] 2. Supported Linux x86_64, WSL-as-Linux x86_64 and macOS arm64 setup uses reviewed exact Herdr version URLs/SHA-256 through engine provisioning, with mismatch rejection before activation. Existing Pi/subagent exact versions and registry integrity remain unless a new pin is explicitly reviewed; hook bytes/revision are recorded. No sudo/OS package manager, unpinned installer, Node bootstrap, repo Go daemon, wrapper service or chezmoi public lifecycle entry is introduced.
- [ ] 3. Repeated scratch-home setup leaves matching binary/hook unchanged and detects drift or unmanaged same-name conflicts without overwriting user data absent explicit takeover approval. Install and verify honor the same target home/PI_CODING_AGENT_DIR. Fixtures preserve unrelated extensions/settings, Herdr config, dummy auth/trust/session files, role overrides and project bindings; no recursive exact-management of user trees occurs.
- [ ] 4. Normal setup/sync/verify demonstrably starts/stops/restarts no Herdr server, opens/adopts no pane or child, scans no live session, resolves no credentials and calls no model/vault API. Normal verification checks exact hook bytes/revision plus actual start/reload discovery/handlers using isolated trusted resources and synthetic events, not existence alone or ambient extensions. Network-denied/offline fixtures document that PI_OFFLINE is not a sandbox.
- [ ] 5. Official semantic-state reporter fixtures cover absent/partial/stale Herdr environment, inherited-environment RPC/JSON/print suppression, TUI pane/session identity, new/resume/fork/reload, settled versus low-level agent end, counted blocked overlap and socket failure/timeouts. Independently test pi-subagents metadata isolation by mode: its hasUI gate does not exclude RPC with inherited Herdr environment, so any gap requires an explicitly accepted limitation or approved upstream resolution before that behavior is promised.
- [ ] 6. Existing subagent, bg_wait, bundled skill and role override verification remains. Fixtures show absent/old/unreachable Herdr affects only optional inspector/project-pane actions without rerouting children or fallback launches. Document and test managed PATH, HERDR_BIN versus HERDR_BIN_PATH, and PI_SUBAGENT_PI_BINARY scope; standalone headless foreground/background operation is preserved.
- [ ] 7. Exact-trio fixtures cover current-session metadata restore/refresh/clear without raw task/goal leakage and the herdr:busy emitter with missing receiver in the inspected selected official route; user-visible effects remain untested until synthetic evidence and human TUI observation are recorded. Accept a documented limitation or explicitly approved upstream resolution/new reviewed pin before promising semantic async-busy behavior. No competing lifecycle publisher or speculative shim is added, and semantic idle alone never proves child completion or safe destructive cleanup.
- [ ] 8. Shutdown/exit/reload compatibility evidence distinguishes Pi core tracked event-bus cleanup and the subagent disposer/flush from the official hook lacking explicit authority release or queued socket-report drain. Test report races/drain, replacement/session identity and observed authority cleanup in separately authorized isolated runtime/TUI checks; record outcomes without inferring leaked listeners, stale authority or a pass from source absence. Required failures gate support pending approved upstream resolution or deliberately accepted limitation.
- [ ] 9. Inspector fixtures verify selected run/child identity, artifact/status reads and acknowledged control via existing subagent authority; closing an inspector never stops its child. Project-pane fixtures verify separate cwd/session/resource discovery, binding identity, stale/foreign binding rejection, explicit idle close guard and human trust requirement. Existing headless runs are never attached/moved/adopted; semantic idle alone cannot authorize peer-child destructive cleanup.
- [ ] 10. Upgrade/offline verification tests leave live servers, sockets and children host-owned; docs distinguish installed binary, integration revision, Pi/subagent pins and runtime server version, report updater drift and give human-only restart guidance. Separately authorized isolated runtime tests check socket owner/mode without touching unmanaged sockets/trees. No public TCP service, SSH/remote auto-install, credential copying or broad config rewrite is added.
- [ ] 11. Before enabling or promising corresponding behavior, record the exact Herdr binary/integration revision/Pi/pi-subagents trio and results of the document compatibility matrix, including absent/no-server/headless/TUI/async/blocked/reload/inspector/project-pane cases. Relevant fast checks and TASK-34-final scratch-apply/verify harness pass on Linux/WSL and macOS arm64, with explicit human terminal evidence and accepted limitations; no generated state is committed. Platform libc/OS/quarantine unknowns must be resolved or clearly gate support, never silently trigger OS package installation.

| Scenario | Automated/auth-free scope | Future separately approved human terminal validation |
|---|---|---|
| Herdr absent; Pi/subagents selected | graph + loader/mock behavior; no reporting/launch | ordinary Pi remains usable |
| Herdr installed; no server/no TTY | version/hash/schema inspection where confirmed non-starting, stub failed commands | no GUI/display prerequisite |
| Herdr env partial/stale; RPC/JSON/print | official semantic-report suppression; separately test metadata hasUI/mode isolation and bounded failures | document accepted metadata limitation or approved upstream resolution; no assumed suppression |
| TUI in Herdr; no subagent work | fake socket reports + session identity | idle/working/blocked appearance; trust prompt, abort, compaction |
| Active async run; parent settled | synthetic metadata and busy compatibility gap | verify semantic idle caveat or upstream fix; labels/attention |
| Reload/resume/new/fork/shutdown | handler lifecycle, tracked cleanup and foreign-session fixtures | observe listener cleanup, authority release/report drain and status restoration; no inferred failure |
| Inspector open/control/close | fake Herdr client + synthetic run artifacts | H/Enter focus, transcript, acknowledged steering, close leaves work |
| Cross-project pane | fake client, temporary roots and bindings | target project trust/resources, independent session, safe close |
| Linux / WSL / macOS arm64 scratch home | provision and full offline verify; network blocked after downloads | terminal rendering/keybindings/detach/reattach; macOS execution restrictions |

Use Pi's existing `DefaultResourceLoader` for discovery (installed SDK ResourceLoader section and `examples/sdk/06-extensions.ts`), with controlled cwd/agentDir and only selected trusted resources. The existing verifier loads ambient user extensions; **do not assume that is auth-free just because it sends no prompt**. Extension factories can execute arbitrary code. Future verifier must isolate fixtures and use `PI_OFFLINE=1`/offline settings and network denial where feasible; never call model availability/auth resolution as a health check. `PI_OFFLINE` only documents startup network suppression, not a sandbox preventing arbitrary extensions from networking.

Do not copy SDK examples' `session.prompt` into verification. No new RPC host or embedded service is needed. Human tests involving real agents require separate user approval/provider credentials on that host; prefer synthetic inert tools/events for automated coverage.

## 7. Task-ready specification

### Title

Add optional Herdr + Pi/subagents composition to the workstation capability engine

### Description

After TASK-34 makes workstation authoritative, provide reproducibly pinned Herdr installation and the official Pi integration while preserving existing `pi` and `pi-subagents` capability ownership and headless operation. Make both existing integration directions explicit: pi-subagents reports current-session pane metadata and opens optional inspector dashboards/project-owned Pi panes; Herdr hosts/observes terminals but does not adopt or replace subagent execution. Capture and test actual compatibility, ownership, offline verification, update and user-state boundaries before claiming support.

### Dependency

**TASK-34** (blocking architectural prerequisite). Rebase/reinspect its completed public interface, selection mechanism, context/provision contract and test harness before planning implementation. Snapshot documentation's chezmoi authority statements are stale relative to the approved migration.

### Scope

- Herdr pinned native binary capability, exact platform URLs/checksums, package-local lifecycle/verification and tool inventory docs.
- Optional explicit composition capability owning official Pi hook plus cross-package integration tests/docs; preserve existing Pi/subagent identities and installation methods.
- Resolve composition selection, hook/config ownership and v0.9.0 busy/shutdown caveats before implementation.
- Unchecked acceptance criteria 1–11 and matrices above; sources below are task references.

### Non-goals

No custom subagent daemon/engine, Go module, service wrapper, managed auto-start, new model/provider gateway, GUI desktop dependency, headless-to-pane migration, trust bypass, secrets/auth/session management, remote machines/SSH/VPS/Dokploy infrastructure, Herdr-driven worktree cleanup, undocumented UI config, external CLI fallback, compatibility layers or generic optional-dependency schema expansion on speculation. No implementation status/assignee/plan should imply design approval.

### Risks and open decisions

1. Is workstation installation of Herdr opt-in, or only runtime usage optional? Final selection mechanism must be defined after TASK-34.
2. Approve one full-stack `herdr-pi` composition requiring pi-subagents, or genuine independent plain-Pi support with a second composition. Do not duplicate native bridges.
3. Decide compatibility only after testing: the selected official route lacks a busy receiver (user-visible effects untested); shutdown/exit/reload outcomes remain open despite Pi core and subagent cleanup; RPC metadata isolation differs from the official TUI-only reporter. For required behavior, accept an explicit limitation or obtain approved upstream resolution/new reviewed pin. Do not patch official code silently or infer failure/pass.
4. Choose official installer with ownership/idempotence guard versus checksum-pinned official source deployment, including atomic file activation policy and conflicting user file behavior.
5. Decide Herdr config ownership; whether disable background manifest/version checks as managed policy or leave user-owned defaults and document reproducibility limits. No whole-file clobber without approval.
6. Confirm Linux libc/minimum macOS support, WSL local workflow and macOS signing/quarantine behavior through platform tests; no unsupported prerequisite claims.
7. Verify current server compatibility separately from installed binary. Define human-only restart guidance, never implicit server stop/handoff during apply.
8. Existing project-pane idle close checks and semantic idle are not evidence all peer children finished. The missing receiver in the inspected selected official route has untested user-visible effects. Keep destructive automation out of scope regardless of that unknown.

## Contradictions and limitations

- Snapshot docs prescribe chezmoi public apply; approved TASK-34 explicitly reverses that. This proposal follows TASK-34, not stale docs.
- “Pi integration version 2” in restore docs is a minimum; selected release source is v8. Do not confuse these numbers with Pi 0.85.1.
- Exact pi-subagents source emits `herdr:busy`; the selected official Pi asset has no receiver and inspected Pi dispatch does not synthesize one. Metadata is a separate presentation path. This is not a full-tree/custom-extension audit or runtime/UI verdict.
- Generic explicit release-on-exit guidance is not implemented in the inspected Pi asset, but Pi core tracks event-bus subscription cleanup and pi-subagents has disposal/flush. No leaked listener or stale authority is proven.
- The official hook checks TUI mode; subagent metadata checks hasUI, which can be true for RPC. Do not generalize one gate to the other.
- Upstream manual install docs lack checksum procedure, but GitHub release asset metadata **does** supply SHA-256; absence from docs is not absence of digests.
- No tests, installed Herdr inspection or independent binary hashing were performed. Source checks were inconclusive; original sources were inspected directly. Minimum supported Pi CLI for integration is unverified. No verified dedicated security policy or all-runtime-files permission audit was obtained. A guessed installed `src/integrations/herdr.ts` path did not exist; no claim relies on it—installed docs plus actual client/project-pane code are the local evidence.

## Sources

Kept (primary, focused):
- [Herdr integrations](https://herdr.dev/docs/integrations/#pi) — installation paths, state authority and environment, restore minimum.
- [Herdr v0.9.0 release](https://github.com/herdrdev/herdr/releases/tag/v0.9.0) and [release metadata](https://api.github.com/repos/herdrdev/herdr/releases/latest) — exact assets/digests, server requirement and upgrade behavior.
- [Pinned Pi asset](https://raw.githubusercontent.com/herdrdev/herdr/v0.9.0/src/integration/assets/pi/herdr-agent-state.ts), [targets](https://raw.githubusercontent.com/herdrdev/herdr/v0.9.0/src/integration/targets.rs), [version requirements](https://raw.githubusercontent.com/herdrdev/herdr/v0.9.0/src/integration/version.rs) — source-level behavior rather than inferred docs.
- [Install](https://herdr.dev/docs/install/), [persistence](https://herdr.dev/docs/persistence-remote/), [socket API](https://herdr.dev/docs/socket-api/), [configuration](https://herdr.dev/docs/configuration/), [config reference](https://herdr.dev/docs/config-reference/) — supported manual platform names and public runtime/config surfaces.
- [API server permissions](https://raw.githubusercontent.com/herdrdev/herdr/v0.9.0/src/api/server.rs), [IPC](https://raw.githubusercontent.com/herdrdev/herdr/v0.9.0/src/ipc.rs) — actual Unix 0600 setting, not guessed security guarantees.
- [Pinned subagent extension API](https://github.com/nicobailon/pi-subagents/blob/0fc0eebb9604970c506708b7508d6aa38921fde2/docs/extension-api.md), [observability](https://github.com/nicobailon/pi-subagents/blob/0fc0eebb9604970c506708b7508d6aa38921fde2/docs/observability.md), [configuration](https://github.com/nicobailon/pi-subagents/blob/0fc0eebb9604970c506708b7508d6aa38921fde2/docs/configuration.md), [client](https://github.com/nicobailon/pi-subagents/blob/0fc0eebb9604970c506708b7508d6aa38921fde2/src/inspectors/herdr/client.ts), [project panes](https://github.com/nicobailon/pi-subagents/blob/0fc0eebb9604970c506708b7508d6aa38921fde2/src/inspectors/herdr/project-panes.ts) — installed-version bidirectional contracts.
- [Pi registry](https://registry.npmjs.org/@earendil-works/pi-coding-agent/latest), [subagent registry](https://registry.npmjs.org/pi-subagents/latest) — current versions, exact integrity and gitHead mapping; mutable discovery URLs, not provisioning pins.
- [Pinned Pi extensions](https://github.com/earendil-works/pi/blob/d981de1229ef899957bbe968bc8dcda02a21f477/packages/coding-agent/docs/extensions.md), [SDK](https://github.com/earendil-works/pi/blob/d981de1229ef899957bbe968bc8dcda02a21f477/packages/coding-agent/docs/sdk.md), [packages](https://github.com/earendil-works/pi/blob/d981de1229ef899957bbe968bc8dcda02a21f477/packages/coding-agent/docs/packages.md) — URL counterparts of completely read installed documents; discovery, event lifecycle and package security.
- Snapshot repository files identified above — approved migration and existing contracts; deliberately no evolving main-worktree inspection.

Rejected/deprioritized:
- Search summaries, third-party agent-proxy/grok/web dashboard results — discovery noise, not integration evidence.
- Old versioned Herdr docs/search issue mentioning integration v5 — stale for selected v0.9.0/v8.
- Guessed `/docs/installation/`, `/docs/architecture/`, `/docs/security/` pages — fetched landing-page content rather than authoritative topic pages.
- Performance blog/benchmarks and remote infrastructure — not needed to justify this capability proposal; no performance recommendation made.

## Next steps

The canonical future-work To Do task references this document and depends on TASK-34; import was completed through Backlog CLI after parent review. This researched specification is not an implementation plan or approval. A future worker must first reread the completed TASK-34 interface/contracts/harness, then activate/plan work through the normal reviewed task workflow. Settle package-selection/config ownership and compatibility decisions, verify downloaded digests and the exact trio in isolated auth-free fixtures, and obtain separate approval for human/runtime validation on Linux/WSL/macOS. No implementation begins in this task-writing stage.
