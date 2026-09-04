---
id: TASK-29
title: Harden managed runtime against Omarchy preinstalled toolchains
status: To Do
assignee: []
created_date: '2026-09-03 11:52'
labels:
  - workstation
  - toolchain
  - omarchy
dependencies: []
priority: high
type: bug
ordinal: 45000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Omarchy preinstalled mise-managed toolchains that shadow the workstation-managed ones: node 26.8.1 (repo pins 24.19.0 via home/dot_node-version and nvm path) is active in PATH, and exported GOROOT/GOBIN from mise go 1.27.1 leak into the managed go 1.27.0 builds, making packages/subagents setup fail with 'compile: version go1.27.1 does not match go tool version go1.27.0' until GOROOT/GOBIN are unset. Also ~/.local/share/chezmoi is a stale clone of this repo (041f258) and is the default chezmoi source, so a plain 'chezmoi apply' reverts managed files (it already reverted the tmux pin during TASK-28 recovery).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Workstation lifecycle runs succeed under an Omarchy login shell without manually unsetting GOROOT/GOBIN (configure_runtime or equivalent sanitizes foreign Go env when managed go is used)
- [ ] #2 Managed node resolution is deterministic on this host (managed 24 or an explicit decision to adopt 26, with versions.json/docs updated)
- [ ] #3 Document which chezmoi source is authoritative and how to keep the default-source clone from reverting managed state
<!-- AC:END -->
