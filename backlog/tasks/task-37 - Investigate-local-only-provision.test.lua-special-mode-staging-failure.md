---
id: TASK-37
title: Investigate local-only provision.test.lua special-mode staging failure
status: Done
assignee:
  - '@shyylol'
created_date: '2026-09-10 02:28'
updated_date: '2026-09-10 17:00'
labels: []
dependencies: []
priority: medium
type: bug
ordinal: 52000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
tests/provision.test.lua fails at line 214 on this host EVEN ON A CLEAN TREE (verified via git stash): after api.directory rejects a fixture archive carrying special mode bits (2541), the previously staged good file must remain 'inert' at mode 420 but the assertion fails. check.sh is therefore red locally, cascading into check.test.lua's nested run (line 156). All other suites pass. Likely environment-dependent: local tar version vs CI. Repro: sh .github/scripts/test-home.sh $HOME/.local/opt/nvim/bin/nvim -l tests/provision.test.lua $HOME/.local/share/nvim/mason/bin/stylua $HOME/.local/opt/chezmoi/bin/chezmoi
<!-- SECTION:DESCRIPTION:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Probe tar header-vs-extracted mode behavior (GNU tar 1.35 non-root). 2. In provision.lua extract(): validate member modes from tar -tvf header listing (portable GNU tar + bsdtar first-field permission string) before extraction, keeping -tf name/safe_member checks and order intact. 3. Keep manifest() post-extraction special-mode rejection as defense-in-depth. 4. Run provision-related suites via .github/scripts/test-home.sh isolation + stylua, then full check.sh. 5. Record evidence and finalize.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
AUDIT EVIDENCE (2026-09-10, run from herdr pane w1:p3): GNU tar 1.35 non-root PLAIN extraction strips setuid bits — archive member 4755 extracts as 755 (empirical probe). Suite still fails at provision.test.lua:214 on clean tree. Implication: if the engine's extract invocation also drops special bits for unprivileged users, post-extraction mode validation (manifest special-bit rejection) never sees them, the special-mode archive is NOT rejected, and activation clobbers the previously staged good install — exactly the observed failure. Next steps: (1) inspect provision.lua extract() tar flags (does it pass -p/--same-permissions? does GNU tar honor setuid for non-root then?), (2) decide fix: validate modes from archive HEADERS (tar -tv) instead of extracted stat, or preservation flags, (3) check whether ubuntu-24.04 CI (GNU tar 1.35, non-root runner) is currently red for the same reason or diverges, (4) macOS bsdtar behavior may differ — keep platform-agnostic fix.

FIX (2026-09-10): Root cause confirmed — GNU tar 1.35 non-root extraction strips special bits (probe: header -rwsr-xr-x / 04755 extracts as 755), so manifest()'s post-extraction special-mode rejection never fired; the special-mode archive was accepted and activation clobbered the staged good install (provision.test.lua:214). Fix in workstation/lua/workstation/provision.lua extract(): new safe_mode() parses the HEADER permission string from 'tar -tvf' listing (first field; portable — verified GNU tar 1.35 and libarchive bsdtar both print -rwsr-xr-x / drwxr-xr-t as field 1), rejects setuid (s/S pos 4), setgid (s/S pos 7), sticky (t/T pos 10), fails closed on unparseable fields. Header validation runs after the existing -tf name/safe_member checks (unsafe-name rejection order/message unchanged, still pre-extraction) and before tar -xf; manifest() post-extraction staging rejection kept as defense-in-depth. ZIP path untouched. Evidence: tests/provision.test.lua now passes isolated (test-home.sh), including 04755-member and 01755-dir special-mode fixtures rejecting with 'unsupported special mode' while the good install stays 'inert' mode 420; package-provision/provider/journal suites pass; full sh .github/scripts/check.sh exit 0 (previously red via provision.test.lua:214 cascade into check.test.lua:156); stylua clean. ShellCheck unavailable locally (CI-required, pre-existing). No acceptance criteria were defined on this task; verified against the repro command and suite behavior instead.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Fixed special-mode staging bypass: GNU tar 1.35 unprivileged extraction strips setuid/setgid/sticky bits, so provision.lua's post-extraction manifest() check never saw them and a special-mode archive clobbered the good install (provision.test.lua:214). extract() now validates member modes from 'tar -tvf' HEADER listings (portable GNU tar + bsdtar) before extraction via new safe_mode(); manifest() post-extraction rejection retained. Verified: provision suite (incl. 04755/01755 fixtures), package-provision/provider/journal suites, and full .github/scripts/check.sh all pass (exit 0); stylua clean.
<!-- SECTION:FINAL_SUMMARY:END -->
