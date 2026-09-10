---
id: TASK-37
title: Investigate local-only provision.test.lua special-mode staging failure
status: To Do
assignee: []
created_date: '2026-09-10 02:28'
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
