---
id: TASK-32
title: 1Password Workstation vault integration
status: In Progress
assignee:
  - '@operator'
created_date: '2026-09-08 19:24'
updated_date: '2026-09-08 20:17'
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
- [x] #1 Headless op auth: OP_SERVICE_ACCOUNT_TOKEN in /etc/pi/op.env (root-only, 0600), never printed or committed
- [x] #2 op whoami and op vault get Workstation succeed non-interactively in agent shells
- [x] #3 Repo-owned profile wiring: managed marker blocks source /etc/pi/op.env and /etc/ntfy/notifier.env when present (fixes unmanaged drift)
- [x] #4 Vault item schemas created empty (user populates values in 1Password app): Workstation/ntfy (phone_user, phone_password, notifier_token, operator_user, operator_password, admin_token, server_url), Workstation/dokploy (url, api_key)
- [x] #5 Normal apply/sync/verify/CI remain vault-independent
- [x] #6 docs/secrets.md documents headless setup and env wiring
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Headless auth live: service account workstation-vps (view+edit on Workstation), token in /etc/pi/op.env, exported via managed profile block; fixed silent no-export bug by wrapping env-file sourcing in set -a/set +a (notifier vars now reach child processes in login shells). op whoami + op vault get Workstation verified. Existing user item 'GLM' observed in vault, out of scope. Item creation blocked until user enables 'Allow creating items' for the service account. Profile wiring committed af084a3b.

Service account recreated with write access (permissions immutable; first account was read-only). Vault schemas created: Workstation/ntfy (server_url/phone_user/operator_user filled, 4 concealed fields awaiting user values) and Workstation/dokploy (url filled, api_key awaiting). User item GLM untouched. docs/secrets.md documents headless setup, profile marker blocks, vault item schema, and recovery model. Remaining: user populates concealed fields from /etc/ntfy/credentials.env and /root/.config/pi/dokploy.env.
<!-- SECTION:NOTES:END -->
