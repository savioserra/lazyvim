---
id: TASK-34
title: Make the workstation capabilities engine authoritative over chezmoi
status: In Progress
assignee:
  - '@operator'
created_date: '2026-09-08 21:27'
updated_date: '2026-09-09 00:21'
labels: []
dependencies: []
type: feature
ordinal: 49000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Invert the architecture: the Lua capabilities engine (currently ~/.local/share/workstation, driven by .chezmoiscripts/run_after) becomes the sole public lifecycle interface (workstation apply/update/setup/sync/verify). Chezmoi remains the file-provisioner invoked BY the engine (--source/--destination explicit), never the other way around. Requires repo restructure: engine becomes repo-native (top-level workstation/), chezmoi source shrinks to pure home state, versions.json ownership moves to the engine, bootstrap story changes (no .chezmoiroot, no run_after lifecycle scripts). Planning task: decisions recorded here before implementation.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The workstation CLI is the authoritative lifecycle interface; chezmoi remains a subordinate file backend with explicit source/destination and no lifecycle run-after scripts.
- [ ] #2 The engine-native workstation/ and chezmoi/ layout has explicit package registration and domain-neutral core, with no duplicate engine deployment or removal of the live engine clone.
- [ ] #3 Fresh-host bootstrap succeeds with ordinary system prerequisites and no preinstalled Neovim, Node, Python or jq; exact runtime/backend pins and checksums have one canonical source and safe activation.
- [ ] #4 Setup provisioning validates new, cached and installed artifacts, supports required tar/ZIP layouts, repairs managed drift safely and fails without activating unverified bytes.
- [ ] #5 Scratch destinations isolate runtime, HOME, XDG and cache state and cannot invoke live user-service retirement; update and public symlink launch paths have regression tests.
- [ ] #6 All six externals migrate to owning package setup operations, preserving platform URLs/checksums and managed Node/Pi dependency ordering.
- [ ] #7 Documentation, AGENTS, skills, CI and scratch harness describe and exercise engine authority, supported Linux/WSL and macOS arm64 behavior, and the breaking cutover.
- [ ] #8 Substantive independent review and command evidence pass before publication or live cutover; environment-limited and unrun checks are explicitly reported.
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Recovery checkpoint after phases 1-3 at 1f4b62b0; this CLI-managed plan supersedes the legacy manually appended planning section.
1. Correct the seven accepted aggregate-gate findings: cold shell bootstrap; public symlink resolution; LuaJIT-safe checked update subprocesses; coherent scratch HOME/XDG/runtime environment and no live host-service retirement in alternate destinations; cache plus installed-integrity validation; explicit ZIP format handling; current managed Node PATH after first materialization. Fix ShellCheck and separate offline fixture validation from the bounded chezmoi integration probe.
2. Preserve versions.json as canonical pin ownership. Any shell-readable bootstrap pin manifest is a deterministic generated projection tied to the canonical file and checked for drift; never a second hand-maintained pin source. Shell installs pinned Neovim before Lua; engine then ensures the pinned chezmoi backend is available. No Node/Python/jq/system-Neovim runtime bootstrap dependency, unpinned downloads, sudo or OS package manager.
3. One native worker owns corrections and tests; fresh native reviewer plus command-capable validator must return substantive evidence. Missing structured verdicts block rather than default to pass. Keep all host/service actions confined to synthetic fixtures and do not push/apply live.
4. Only after parent acceptance, continue phase 4 per-package externals migration, phase 5 docs/CI/scratch harness, and phase 6 full supported-platform validation. Live cutover and publication remain gated at the end.

Correction execution: install the shell runtime from a generated SHA-bound pin projection; provision pinned chezmoi from official v2.72.1 release checksums; isolate environment before dispatch; validate installations against verified staging, with rollback and explicit archive formats; add synthetic bootstrap/update/retire/Node/integrity fixtures and replace the real-source unit dry-run with an offline backend fixture. Full-source dry-run remains a separate later integration gate.

Recovery pass 2: repair only the two accepted 4dc642c review findings before phase4. Preserve validated account-session rendezvous for ownership-approved real-home retirement children without weakening alternate-home isolation; add child-environment tests. Compare full managed permission bits, including special bits, and test drift repair/rejection. One native worker then independent source/command gates; no live service calls or deployments.

Parent-approved adjacent P2 correction: retain unrelated non-exact special-mode regression and add only portable cp -p metadata preservation to the existing -R -P copy; no overlay redesign. Verified staging continues to reject special bits; unrelated existing state has a distinct ownership boundary.

Phase4 now active: inventory and migrate all six .chezmoiexternals declarations (foundation, Neovim, Go, Node/nvm, fonts, 1Password) to single owning engine/package operations. Neovim stays bootstrap-owned; other assets move into owning setup using context.provision. Preserve exact existing pins/URLs/digests, supported platforms, extraction layout, Node sequencing and mutable ownership. Remove externals plus temporary versions bridge; preserve explicit catalog/domain-neutral core and no duplicate bootstrap source. Add offline package/spec parity/order tests, run full current fixture/lint suite, and only after source audit and complete external removal attempt a bounded isolated real-source chezmoi dry-run without relaxing prior guards. Independent source and command gates are required before phase5. No host installs, providers/vaults, service calls, publication or cutover.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Original workflow b38d0752 failed at phase-3 reviewer timeout (1800000ms); earlier phase1/2 saved review files were narration-only and cannot be accepted as gates. Recovery workflow 560bf1c1 completed with explicit blocked source and command verdicts at clean main 1f4b62b0. Seven implementation defects accepted for repair; cache-tampering and cold-bootstrap failures reproduced in isolated fixtures. The provision suite file-size-bound failure is a validation limitation under investigation, not proof of a general product regression or download-free behavior. ShellCheck SC1007 needs correction. No real-host cutover/push performed. Durable complete review is stored in /tmp/pi-subagents-uid-0/async-subagent-runs/560bf1c1-8cee-40c9-8072-333efd48538c/status.json workflow.value.review.structuredOutput; its advertised Markdown report is empty. Command report is in the workflow output artifacts and logs at /tmp/task34-validation.EKDwJg/.

Correction pass implemented all seven accepted source findings: POSIX cold Neovim installer with generated SHA256-bound canonical pin projection, checksum-before-extraction, serialized runtime/backend bootstrap and rollback; portable final-script symlink resolution; checked argv update children; pre-dispatch HOME/XDG/runtime/cache isolation and OS-account/service-file guarded retirement without success markers on skip/failure; verified cache and installed staging manifests (modes/completeness), exact repair/non-exact recursive state preservation and activation rollback; explicit/original-spec ZIP dispatch; refreshed managed Node PATH after materialization. Added engine-owned chezmoi 2.72.1 backend pins from official GitHub release checksum metadata; existing pins unchanged. No live lifecycle/service commands or host software installation performed.

Fixture evidence: capabilities.test.lua, rewritten provision.test.lua, new cli.test.lua and bootstrap.test.lua all exit 0 with isolated HOME/TMP/XDG roots, 120-second timeout and 4096-block file-size guard. ShellCheck, sh syntax, full scoped StyLua check, generated manifest --check and git diff --check exit 0. Logs: /tmp/task34-repair-logs/. Initial provision fixture attempt exposed absent zip command; replaced archive generation with tiny source-managed stored-ZIP fixture builder (no installed dependency) and reran successfully. Backend/download/service/model actions are fake or stubbed; no real provider calls. Official metadata only: /tmp/task34-repair-metadata/{release.json,checksums.txt}.

Bounded prior chezmoi failure investigated from saved evidence without rerunning or relaxing limits: /tmp/task34-validation.EKDwJg/cache/chezmoi includes external assets and a 4194304-byte lazygit HTTP-cache entry. --exclude externals did not establish an offline unit-test boundary. Unit argv validation now executes only a tiny fake backend; full real-source materialization remains an explicitly unrun later integration gate, not waived as passing. Linux x86_64 fixture checks only; Darwin branch simulated, not native macOS/WSL runtime validation. Phases 4-6 remain deferred: six externals/package migration, temporary versions symlink removal, public deployment/docs/AGENTS/skills/CI/harness cutover, full supported-platform apply/verify. All eight ACs remain unchecked and task remains In Progress pending independent review/command gates.

Correction workflow 76bc737d completed: independent four Lua suites, shell/format/manifest/diff checks passed at clean 4dc642ced3b63815dec748e4e13007f2cdd63f05. Gate remains blocked by P1 unconditional XDG_RUNTIME_DIR override breaking real-account Linux retirement bus discovery when DBUS_SESSION_BUS_ADDRESS is unset, and P2 installed mode comparison masking only 0777 and missing special-bit drift. Both source findings accepted for narrow repair; no live-manager reproduction or host mutation occurred. Full structured review is in /tmp/pi-subagents-uid-0/async-subagent-runs/76bc737d-7ebe-4b14-8148-652c3514c083/status.json (the advertised source-review Markdown is again empty); independent logs /tmp/task34-independent.27N577/logs. Parent imported reviewed future-work TASK-35/doc-1 through CLI at the released writer boundary, with all 11 ACs unchecked and no Herdr implementation.

Recovery pass 2 implementation: preserve first incoming session runtime/DBus hints across shell, direct Lua and repeated launcher children while all normal writable roots stay target-private and ambient DBus is unset. Owned real-account Linux retirement alone validates an existing canonical 0700 account-owned runtime plus owned local bus socket and accepts unset DBus or exact unix:path=<runtime>/bus; unsupported/missing context aborts without a child or success marker. Per-child clear_env uses the current normalized environment with only rendezvous overrides (vim.system stringifies false, so unset must be represented by omission). No live endpoint connection or /run path mutation. P2 compares full 07777 and rejects special modes in staged artifacts/explicit file modes. Shell bootstrap has no installed-mode comparison to truncate: it always replaces from verified extraction, so no matching gap was found there.

Worker self-checks (not independent acceptance): final capabilities/provision/cli/bootstrap suites all exit 0; shell sh-n x2, ShellCheck, full scoped StyLua, generated pin manifest --check and diff --check all exit 0. Final logs: /tmp/t34-session.1nzXWn/logs; repeatable scratch/guard runner /tmp/task34-session-validation.sh and checks runner /tmp/task34-session-checks.sh. Fixtures use env -i, scratch HOME/TMP/XDG, timeout 120, ulimit -f 4096 and controlled commands; fake systemctl records actual child ENV for direct/shell/repeated launches, unset/exact-local DBus, invalid/missing/symlink/unsafe contexts, alternate-account target and child failure. Bound non-listening scratch sockets model only metadata, with no endpoint contact. Provision regressions inspect inert 04755/02755/01755 file drift, sticky exact roots, privileged staging rejection and unrelated non-exact file/directory modes for tar/ZIP; rollback and ordinary state coverage pass.

Exact earlier failures retained: bash /tmp/task34-session-validation.sh first exited 1 in provision.test.lua (unrelated non-exact mode changed), logs /tmp/t34-session.0niFqw/logs; parent approved adjacent preservation repair, so the assertion is retained and cp -p added to existing -R -P (GNU help confirms mode/ownership/timestamp semantics; portable POSIX flag, native Darwin semantics/execution not independently checked here). Second attempt exited 1 in cli.test.lua because vim.system env=false became the literal DBus value false, logs /tmp/t34-session.Rc4Lq3/logs; fixed by clear_env plus normalized environment and omission for unset DBus. Subsequent all-four-suite passes: /tmp/t34-session.Z9ZjRB/logs and /tmp/t34-session.ycc1wW/logs, with final post-preservation pass at /tmp/t34-session.1nzXWn/logs. No unresolved fixture failure. Metadata preservation is not a comprehensive ACL/xattr/hardlink/crash-safety claim. Runtime/socket metadata cannot prove liveness; a stale session still fails through checked child status and cannot produce a new marker. Native macOS arm64/WSL, real service connectivity, real-source chezmoi external-resolution integration and phases 4-6 remain deferred. Task remains In Progress with no AC changes; Herdr TASK-35/doc-1 untouched. Independent source and command review remain required before parent acceptance.

Parent accepts the correction checkpoint 146fee8cabb6605245da194df38fce1751683f54 for continuation after workflow 37c2450a returned substantive independent source PASS and command PASS. Parent read both complete reports and confirmed exact clean HEAD/main. Independent four Lua suites, actual fake-child session ENV instrumentation, full special-mode/staging/non-exact preservation assertions, shell/format/manifest/diff checks all exit 0; logs /tmp/task34-independent-session.m0n7vf/logs. This clears the known phase1-3 source/fixture blockers only, not task-wide acceptance or native macOS/WSL/live-service/full-source integration. No ACs checked and no live deployment/push. Phase4 is now authorized within the original approved migration scope.

Phase4 implementation underway under the accepted plan: original six declarations snapshotted and resolved into bounded parity evidence before removal; their URL templates/digests migrate to canonical versions.json with unchanged versions. Parent confirmed first-apply Node seam remains authoritative: direct setup with missing/invalid materialized pin fails before any Node/nvm operation and instructs apply; no source fallback or duplicate Node version. Package-owned setup uses existing provisioning API, with nvm/Node explicitly non-exact. No AC changes or phase5/Herdr work.

Phase4 implemented (worker checks, not independent acceptance): foundation provisions rg/fd/fzf/lazygit/tree-sitter/rainfrog; Go provisions its exact toolchain; Node provisions non-exact nvm then Node before alias/environment and dependent npm/Pi; fonts provision before cache/registration; secrets provisions op and verifies only --version. Neovim remains existing engine bootstrap-owned; chezmoi backend unchanged. All existing versions/URLs/SHA256/layouts preserved in canonical versions.json metadata, sole Node version stays chezmoi/dot_node-version, generated SHA-bound bootstrap projection refreshed. All six externals and temporary versions bridge removed after complete template/include/source audit; narrow .chezmoiremove entry removes only .local/share/workstation/versions.json, never clone root or nested workstation/versions.json. Catalog remains 12; generic core, Neovim sync/profile and existing four suites unchanged. Added frozen original-derived spec fixture and package-provision suite covering Linux/WSL mapping, simulated Darwin, full URL/digest/member/layout/mode/exact parity, no module/status/composition downloads, ordering, repeatability, first real CLI refresh with canonical pin/no ambient Node, missing/invalid pin zero operations, nvm/Node failure before configuration, non-exact npm ownership policy and version-only op verify. Tests use scratch roots and stub all package/lifecycle/download/provider actions; existing provision/CLI/bootstrap synthetic extraction, fake-child ENV and full special-mode regressions retained.

Phase4 final commands: bash /tmp/task34-phase4/validate.sh, checks.sh and render.sh all exit 0; final logs /tmp/t34-phase4.JhSDtd/logs with per-command .exit files. Five pinned-Neovim suites passed; sh -n for launcher/installer, ShellCheck both, full workstation/chezmoi Neovim/tests StyLua, generated projection --check and git diff --check passed. All fixture runs use env -i scratch HOME/TMP/all XDG, timeout 120 and ulimit -f 4096. Source audit proved exactly five inert/local shell-or-symlink templates, no externals/scripts/config/data/encrypted sources or source symlinks; modify shell only prints literal environment/auth snippets and does not execute them. Existing installed absolute /root/.local/opt/chezmoi-2.72.0/chezmoi directly ran new full-source apply --dry-run --verbose inside unshare --net with explicit source/destination/config/cache/persistent-state, scratch roots and same 4096 guard; exit 0, 93713-byte stdout, empty stderr, destination unchanged, no guard hits, no backend installation. This is a Linux file-render integration pass only, not lifecycle/live apply or native macOS/WSL. Earlier attempts retained: /tmp/t34-phase4.x1VqTh package suite exit 1 (fixture omitted required nvim_profile, fixed); /tmp/t34-phase4.ouJEz9 StyLua exit 1 (new test import ordering, fixed). No unresolved test/infrastructure failure. Phase5 README/AGENTS/skills/CI/harness/public-launcher authority rewrite and safe ownership-inspected legacy engine payload cleanup remain deferred; no blanket clone deletion, live cutover/install/retirement/service/secret calls, publication or push. Independent source/command gates required before continuation; all ACs remain unchecked and TASK-35/doc-1 untouched.

Integration qualification from parent: the structural full-source dry-run used existing installed chezmoi 2.72.0, while canonical engine backend is 2.72.1. It does not validate the exact pinned backend/runtime bootstrap or full apply/setup. Exact 2.72.1 bootstrap plus integration remains phase6; no backend download/install was attempted to close that distinction.
<!-- SECTION:NOTES:END -->

## Plan

### Current state
- Chezmoi is the entry: `chezmoi init/apply/update` drives everything; `.chezmoiroot` -> `home`.
- `.chezmoiscripts/run_after_20-unix-apply.sh.tmpl` invokes `nvim -l .../run.lua setup` + `sync`.
- Engine (home/dot_local/share/workstation) has zero chezmoi references — the inversion seam is already clean.
- Engine source is deployed BY chezmoi (circularity to break).

### Target state
- Public interface: `workstation <apply|update|setup|sync|verify|diff>` shim in ~/.local/bin.
- Engine invokes `chezmoi --source <repo>/chezmoi --destination $HOME apply` as its file-provisioner step, then runs capability lifecycles itself.
- run_after lifecycle scripts die; .chezmoiremove/.chezmoiignore/.chezmoiexternals stay chezmoi-side.

### Revised design (2026-09-08): provision primitives in setup, no blueprint slot

Capability contract is UNCHANGED: {id, requires, setup, sync, verify}. Tool/file
materialization becomes setup's job via engine primitives; no chezmoi mechanism
(externals/blueprint) ever appears in the contract.

- New `workstation.provision` module: archive/file/directory primitives
  (cache download, sha256 verify, extract, atomic install, skip-if-current,
  platform shims for sha256sum/shasum/tar/unzip flags).
- Packages call context.provision.* in setup; pins stay in engine-owned
  versions.json; ordering comes from the existing requires graph.
- .chezmoiexternals are ELIMINATED (all six). Chezmoi becomes pure home state:
  dotfiles, templates, .chezmoiremove/.chezmoiignore only.
- nvim cannot provision itself (engine runs on it): D2 resolved to pure
  workstation bootstrap - the bootstrap step downloads pinned nvim before the
  engine's first run. No chezmoi init escape hatch.
- Fonts package needs a directory primitive (replaces chezmoi exact=true).

### Phases
1. **Repo restructure**: `home/dot_local/share/workstation/*` -> top-level `workstation/`; remaining home state -> `chezmoi/`; versions.json -> engine-owned; drop `.chezmoiroot`; tests/CI paths updated.
2. **Provision primitives + chezmoi provisioner**: workstation.provision module (archive/file/directory); provisioner wrapping chezmoi for dotfiles (explicit source/destination, --exclude scripts); engine self-location.
3. **CLI surface + bootstrap**: bin/workstation shim (nvim -l), subcommands apply/update/sync/verify/diff/status (update = git pull + apply + sync + verify); bootstrap downloads pinned nvim.
4. **Externals migration**: move all six externals into per-package setup calls (foundation tools, nvim runtime, go, node, fonts, op), delete .chezmoiexternals.
5. **Host cutover + docs**: install shim, retire direct chezmoi usage; rewrite README/docs/AGENTS/skill to the new authority model.
6. **Cleanup**: old paths into .chezmoiremove, test-apply.sh becomes workstation-driven, CI matrix runs the new flow.

### Open decisions (blocking implementation)
- D1 RESOLVED (2026-09-08, operator): git clone at ~/.local/share/workstation; the clone serves as both engine home and chezmoi source parent; workstation update = git pull + full lifecycle.
- D2 RESOLVED: pure workstation bootstrap (engine bootstrap downloads pinned nvim). Forced by provision-in-setup design.
- D3 RESOLVED (operator): workstation/ + chezmoi/ at repo root.
- D4 RESOLVED (operator): engine retire phase (run_once_before scripts ported into engine-managed retire data).

### Risks
- Bootstrap circularity (nvim <-> engine <-> chezmoi) — resolved by D2.
- Scratch-apply harness + CI rewrite.
- Mac host migration (interacts with TASK-29 Omarchy hardening).
- Engine self-update while running from a clone (stage pull before exec).

### Acceptance criteria (draft)
- [ ] `workstation <cmd>` is the only public lifecycle interface; direct chezmoi invocation is internal
- [ ] Repo layout is engine-native; chezmoi source contains no engine code and vice versa
- [ ] Engine invokes chezmoi with explicit --source/--destination; no .chezmoiroot, no lifecycle run_after scripts
- [ ] Fresh-host bootstrap documented and proven in a scratch home (clone -> workstation apply -> verify complete)
- [ ] CI runs the workstation-driven flow on ubuntu-24.04 + macos-15
- [ ] Docs, AGENTS architecture rules, and the lazyvim skill describe the inverted authority
- [ ] All six .chezmoiexternals eliminated; tool provisioning lives in per-package setup via provision primitives with sha256 verification and atomic install
- [ ] Breaking cutover, no compat wrappers (sole consumer)
