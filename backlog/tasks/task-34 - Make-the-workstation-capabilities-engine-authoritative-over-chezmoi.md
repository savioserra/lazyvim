---
id: TASK-34
title: Make the workstation capabilities engine authoritative over chezmoi
status: In Progress
assignee:
  - '@operator'
created_date: '2026-09-08 21:27'
updated_date: '2026-09-08 21:39'
labels: []
dependencies: []
type: feature
ordinal: 49000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Invert the architecture: the Lua capabilities engine (currently ~/.local/share/workstation, driven by .chezmoiscripts/run_after) becomes the sole public lifecycle interface (workstation apply/update/setup/sync/verify). Chezmoi remains the file-provisioner invoked BY the engine (--source/--destination explicit), never the other way around. Requires repo restructure: engine becomes repo-native (top-level workstation/), chezmoi source shrinks to pure home state, versions.json ownership moves to the engine, bootstrap story changes (no .chezmoiroot, no run_after lifecycle scripts). Planning task: decisions recorded here before implementation.
<!-- SECTION:DESCRIPTION:END -->

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
