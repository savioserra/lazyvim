---
id: TASK-25
title: Remove concrete environment assumptions from Go test fixtures
status: To Do
assignee: []
created_date: '2026-09-02 15:26'
labels: []
dependencies: []
references:
  - services/subagents/internal/hostedpi/runtime_linux_test.go
  - services/subagents/internal/service
  - services/subagents/internal/actors/agent_registry_test.go
  - services/subagents/internal/hostedpi/introspection_test.go
priority: medium
type: chore
ordinal: 41000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Audit services/subagents Go tests and replace scattered concrete absolute paths, fixed local endpoints, and machine-shaped fixture values with portable test-owned paths and shared fixture builders. Preserve deliberate protocol defaults and security/redaction attack strings only where the literal value is the behavior under test, and document those exceptions so synthetic fixtures cannot be mistaken for deployment configuration.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Tracked Go test code contains no real developer username, home directory, Pi session UUID, hosted tmux session ID, crew worktree, hostname, or other captured host-specific value
- [ ] #2 Filesystem fixtures use t.TempDir and filepath.Join unless an absolute-path or redaction literal is explicitly the subject of the test
- [ ] #3 Repeated hosted runtime configuration uses a shared test fixture builder rather than scattering /tmux, /pi, /bridge, /credential, and /project literals across service tests
- [ ] #4 Network tests use test-owned ephemeral loopback listeners unless the documented 127.0.0.1:17213 product default is explicitly under test
- [ ] #5 POSIX-only path and argv assertions are scoped to platform-specific tests, while portable tests avoid host-OS path assumptions
- [ ] #6 Security and redaction tests retain representative hostile path strings but label them as intentional payload fixtures and never resolve or access those host paths
- [ ] #7 Go race tests, vet, codegen verification, protocol tests, and git diff checks pass after normalization
<!-- AC:END -->
