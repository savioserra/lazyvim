---
id: TASK-36
title: >-
  Deploy lazy-lock.json as engine-seeded, runtime-extended mutable state via a
  package-owned modify merge program
status: Done
assignee: []
created_date: '2026-09-10 01:41'
updated_date: '2026-09-10 02:36'
labels: []
dependencies: []
type: bug
ordinal: 51000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
REWRITTEN after council (oracle+reviewer) rejected the original pin-aether variant as host-state coupling (upstream Omarchy contract rejected by owner; drop-import also rejected). Root cause: lua/plugins/theme.lua intentionally imports an external desktop-theme spec; lazy.nvim records the ACTIVE spec set into lazy-lock.json; the whole-file recipe byte-compared the deployed copy and fail-closed with 'target changed since the last successful apply' on every Omarchy host. Accepted design (zero engine changes): lazy-lock.json deploys through a package-declared kind=modify recipe whose merge program seeds the committed asset verbatim on absent/empty targets, reconciles drift (engine pins win wholesale; host extras with an installed plugin directory preserved; stale extras pruned; malformed JSON fails closed), and serializes in lazy.nvim's canonical one-line format. Verify asserts every engine pin present at exact branch/commit AND installed at that commit; extras audit-only. mason-lock.json unchanged. Docs: nvim.md lockfile semantics, capabilities.md blessing whole-body package modifiers, chezmoi.md cross-link, tools.md, packages/nvim/AGENTS.md. Tests: nvim-lockfile.test.lua merge semantics, journal.test.lua file-to-modify recipe swap over runtime drift, backend-render fixture nvim + byte parity.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 lazy-lock.json deploys via a package-declared kind=modify recipe; no engine-code change; core stays domain-neutral
- [x] #2 merge program seeds the committed asset verbatim on absent/empty targets and reconciles drift: engine pins win, installed host extras preserved, stale extras pruned, malformed JSON fails closed, output byte-stable
- [x] #3 verify asserts every engine pin at exact branch/commit installed at that commit; extras reported audit-only; mason-lock unchanged whole-file
- [x] #4 tests: nvim-lockfile merge semantics suite, journal file-to-modify recipe-swap case, backend-render fixture Neovim + byte parity all green
- [x] #5 workstation apply/sync/verify pass on this Omarchy host; plain headless session and repeated apply leave the deployed lockfile byte-stable; aether survives as audit-only extra
- [x] #6 docs updated honestly: nvim.md lockfile semantics, capabilities.md whole-body modifier blessing, chezmoi.md cross-link, tools.md, packages/nvim/AGENTS.md
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Merge program template asset files/modify/lazy-lock.json.sh (self-extracting sh+Lua via heredoc, pins marker replaced at contribution time). 2. nvim/init.lua: swap recipe file->modify (executable), embed committed pins verbatim, rewrite verify (engine pins strict + installed-at-commit; extras audit-only incl. relaxed existing installed-dir loop). 3. Tests: new nvim-lockfile suite (seed verbatim, fast path, extra preserved/pruned, engine wins, malformed fails, round-trip stable), journal recipe-swap case, backend-render install_nvim fixture. 4. Docs updates. 5. Isolated checks (check.sh suites; provision.test.lua pre-existing local failure filed as TASK-37). 6. Real-host rollout: apply converges drifted lockfile, sync, verify, plain-session stability, idempotent re-apply.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Council: oracle(fork)+reviewer, converged pass 1 of 2; reviewer structured-output fell back to JSON-text per skill contract. Implementation: files/modify/lazy-lock.json.sh template + init.lua contribution-time pin embedding; verify rewritten (engine pins strict + git rev-parse HEAD match; extras audit-only; existing installed-dir loop relaxed for extras only). Validation: nvim-lockfile/journal/backend-render suites green standalone; stylua clean; sh -n clean; git diff --check clean. Real host (Omarchy, aether theme): apply converged the drifted lockfile without operator surgery (engine pins restored, aether@567efb7 preserved as installed extra, mode 0755), sync green, verify 11/0 with audit line 'nvim: lockfile extra: aether', plain headless session and repeated apply byte-stable. Full check.sh is blocked ONLY by pre-existing provision.test.lua local failure (clean-tree repro verified; filed TASK-37). workstation update requires a clean tree: pull --ff-only correctly refused with these uncommitted changes; commit pending owner approval.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Replaced the byte-owned lazy-lock.json whole-file recipe with a package-declared kind=modify merge program (engine-seeded, runtime-extended mutable state): engine pins from the committed asset win on drift, host extras with installed plugin dirs are preserved (aether on Omarchy hosts), stale extras pruned, malformed JSON fails closed, seed path byte-identical to the asset. Verify now asserts engine pins present+installed at pinned commits with extras audit-only. Zero engine-code changes; no Omarchy-specific code. Verified by new nvim-lockfile suite, journal recipe-swap case, backend-render parity with a fixture Neovim, and full real-host apply/sync/verify with byte-stability under plain sessions and repeated applies. Original 'target changed since the last successful apply' failure class is gone.
<!-- SECTION:FINAL_SUMMARY:END -->
