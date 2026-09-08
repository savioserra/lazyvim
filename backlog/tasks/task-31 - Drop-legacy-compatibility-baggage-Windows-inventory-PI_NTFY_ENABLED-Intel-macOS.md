---
id: TASK-31
title: >-
  Drop legacy compatibility baggage: Windows inventory, PI_NTFY_ENABLED, Intel
  macOS
status: Done
assignee:
  - '@operator'
created_date: '2026-09-08 18:23'
updated_date: '2026-09-08 19:13'
labels: []
dependencies: []
ordinal: 46000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The sole consumer does not need backwards compatibility or speculative platform support. Remove the retained native-Windows removal inventory (platform adapter, host helpers, package backends, graph tests, nvm_windows pin, external variants, ignore branch, doc mentions), the redundant PI_NTFY_ENABLED kill switch from pi-ntfy-notifier, and all Intel-macOS (darwin-x86_64) variants including the macos-15-intel CI runner and fd_darwin_x86_64 override.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 No windows platform adapter, host helper, or package backend remains and the Linux/macOS graphs and tests still pass
- [x] #2 versions.json drops nvm_windows and fd_darwin_x86_64; externals have no windows or darwin-x86_64/amd64 variants
- [x] #3 CI matrix is linux + macos-15 (arm64) only
- [x] #4 Docs and AGENTS files describe Linux/WSL-as-Linux/macOS only with no Windows inventory language
- [x] #5 pi-ntfy-notifier has no PI_NTFY_ENABLED; enablement is presence of PI_NTFY_SERVER and PI_NTFY_TOPIC; tests and README updated; deployed copy refreshed
- [x] #6 All fast checks pass: capabilities tests, stylua, git diff --check, chezmoi dry-run; host apply and verify lifecycle stay green
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Removed platforms/windows.lua, host/windows_environment.lua, fonts/win32.lua, node/windows.lua; unwrapped win32 branches in platforms/init, node/init+managed, foundation, symlink_go, .chezmoiignore, .gitattributes; stripped all windows and darwin-x86_64/amd64 variants from the six externals; versions.json drops nvm_windows and fd_darwin_x86_64; CI matrix is ubuntu-24.04 + macos-15; docs/AGENTS files now state Linux/WSL/macOS (arm64) with no removal-inventory language; capabilities tests assert windows helpers are absent. pi-ntfy-notifier 0.3.0 drops PI_NTFY_ENABLED (enablement = PI_NTFY_SERVER+PI_NTFY_TOPIC present); 11/11 tests pass; deployed copy refreshed. Fixed a latent remote bug surfaced by the first full apply: tmux verify still asserted the retired powerline glyph instead of the vertical-separator theme; it now asserts the tmux2k managed status script. Also dropped the stale ntfy-notifier entry from .chezmoiremove (kept extension). Verified: capabilities tests, stylua, git diff --check, chezmoi dry-run, host apply + verify complete (linux), and full .github/scripts/test-apply.sh scratch-home run.

Committed and pushed: 3f0d6c1f (cleanup, TASK-31) and 968e1255 (1Password vault rename LazyVIM -> Workstation in secrets skill and docs). Working tree clean.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Dropped all legacy compatibility baggage for the single-consumer policy: the native-Windows inventory (adapter, host helper, package backends, externals variants, nvm_windows/fd_darwin_x86_64 pins, ignore branch, graph tests, doc language), the PI_NTFY_ENABLED flag from pi-ntfy-notifier, and Intel-macOS support including the macos-15-intel CI runner. Verified with capabilities tests, stylua, chezmoi dry-run, host apply+verify, and a full scratch-home apply ending in verify complete (linux).
<!-- SECTION:FINAL_SUMMARY:END -->
