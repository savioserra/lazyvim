---
id: TASK-32
title: 1Password Workstation vault integration
status: In Progress
assignee:
  - '@operator'
created_date: '2026-09-08 19:24'
updated_date: '2026-09-08 19:25'
labels: []
dependencies: []
ordinal: 47000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Wire headless 1Password access for the workstation: vault-scoped service account, /etc/pi/op.env token file (root-only), repo-owned profile wiring for host-local env files, and Workstation vault item schemas for ntfy and dokploy credentials (recovery/source-of-truth model; /etc files stay the live mechanism). Vault renamed from LazyVIM to Workstation on 2026-09-08.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Headless op auth: OP_SERVICE_ACCOUNT_TOKEN in /etc/pi/op.env (root-only, 0600), never printed or committed
- [ ] #2 op whoami and op vault get Workstation succeed non-interactively in agent shells
- [ ] #3 Repo-owned profile wiring: managed marker blocks source /etc/pi/op.env and /etc/ntfy/notifier.env when present (fixes unmanaged drift)
- [ ] #4 Vault item schemas created empty (user populates values in 1Password app): Workstation/ntfy (phone_user, phone_password, notifier_token, operator_user, operator_password, admin_token, server_url), Workstation/dokploy (url, api_key)
- [ ] #5 Normal apply/sync/verify/CI remain vault-independent
- [ ] #6 docs/secrets.md documents headless setup and env wiring
<!-- AC:END -->
