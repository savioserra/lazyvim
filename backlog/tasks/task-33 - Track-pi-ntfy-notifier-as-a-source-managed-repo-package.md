---
id: TASK-33
title: Track pi-ntfy-notifier as a source-managed repo package
status: Done
assignee:
  - '@operator'
created_date: '2026-09-08 20:46'
updated_date: '2026-09-08 20:50'
labels: []
dependencies: []
ordinal: 48000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Migrate /root/pi-ntfy-notifier (v0.3.0, secret-free since 0.2.0) into the lazyvim repo: chezmoi-managed extension source at ~/.pi/agent/extensions/ntfy-notifier, a workstation package with version pin and verify (files + version + node tests), catalog registration, tests, docs; retire the out-of-repo source tree.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Extension source lives in the repo and deploys to ~/.pi/agent/extensions/ntfy-notifier via normal apply
- [x] #2 packages/pi-ntfy-notifier registered in catalog after pi-web-access; versions.json pins pi_ntfy_notifier
- [x] #3 verify checks manifest version, extension entry file, and runs the node test suite; stays PI_NTFY-env-independent
- [x] #4 capabilities tests cover the new package; stylua, dry-run, apply, verify green
- [x] #5 docs/tools.md documents the source-managed extension row
- [x] #6 /root/pi-ntfy-notifier retired after migration
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Extension source migrated to home/dot_pi/private_agent/extensions/ntfy-notifier (package.json manifest, extensions/ntfy-notifier.ts entry, src/ntfy.js, test suite, README) deployed by normal apply; packages/pi-ntfy-notifier verifies manifest version against versions.json pi_ntfy_notifier=0.3.0, extension entry declaration, required files, and runs node --test in the extension directory; catalog order pi -> pi-web-access -> pi-ntfy-notifier (12 packages); capabilities tests updated (no verify.mjs for source-managed packages - the node suite is the verifier); docs updated in capabilities.md and tools.md. /root/pi-ntfy-notifier deleted.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
pi-ntfy-notifier is now a source-managed repo package: chezmoi deploys the extension, a workstation package pins and verifies it (manifest, files, node tests), and the out-of-repo source tree is retired.
<!-- SECTION:FINAL_SUMMARY:END -->
