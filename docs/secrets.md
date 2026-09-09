# Secrets reference

## Components

| Component | Contract |
| --- | --- |
| `secrets` capability | Verify the pinned 1Password CLI; do not inspect authentication or vault state |
| `Workstation` vault | Dedicated scope for this workstation's secrets |
| `/skill:secrets` | Explicit-only policy for safe metadata, references, and approved mutations |
| Chezmoi source | Store `op://` references and non-secret schema only |

The capability name describes the workstation concern; 1Password is its current
backend. The desktop application, account session, and vault contents remain
host-owned mutable state.

## Boundaries

- Normal apply, sync, verify, and CI never require vault authentication.
- Never commit or render secret values into persistent configuration.
- Prefer `op run` or `op inject` over retrieving values into agent context.
- Enter secret-reference/vault work only when the user explicitly invokes `/skill:secrets`; other skills must request that invocation, not invoke it automatically.
- Scope every operation to the `Workstation` vault.
- Require explicit user approval for each create, edit, archive, or delete.
- Use a vault-scoped service account when technical enforcement is required on a headless host.

## Desktop authentication

```text
Unlock 1Password
  -> Settings > Developer > Integrate with 1Password CLI
  -> op whoami
```

## Headless setup (servers)

Interactive account sessions do not exist on headless hosts. Use a vault-scoped
service account instead:

1. Create a service account at 1Password.com (Developer tools -> Service
   accounts). Permissions are immutable after creation: grant the
   `Workstation` vault with read and write access at creation time.
2. Place the token in `/etc/pi/op.env` (root-only, mode 0600):

   ```bash
   read -rs OP_SA_TOKEN
   printf 'OP_SERVICE_ACCOUNT_TOKEN=%s\n' "$OP_SA_TOKEN" > /etc/pi/op.env
   chmod 600 /etc/pi/op.env && unset OP_SA_TOKEN
   ```

3. The managed `~/.profile` block (`# chezmoi: managed op env`) auto-exports
   `/etc/pi/op.env` in login shells when the file exists. The same pattern
   applies to `/etc/ntfy/notifier.env` (`# chezmoi: managed ntfy notifier env`).

These are operator-run steps, not commands for an agent to execute. Values never
enter Git, agent context or chat; `/etc` files stay the live mechanism and the
vault is the recovery source of truth. Service account tokens cannot be rotated
in place; revoke and recreate the account to change access.

## Authentication recovery

Within an explicitly invoked secrets workflow, failed authentication/vault checks
stop further operations. Desktop users should unlock the app and restore CLI
integration. Headless operators should restore their service-account environment
and `Workstation` permissions out of band, recreating the account if necessary.
Never ask for or inspect the token value, print account/vault details, or start an
interactive sign-in flow. A missing `op` is an installation issue; use the
[install guide](../README.md), not an implicit authentication-time install.
Normal lifecycle verification remains version-only.

## Vault items

| Item | Non-secret fields (managed) | Secret fields (populate in 1Password) |
| --- | --- | --- |
| `ntfy` | `server_url`, `phone_user`, `operator_user` | `phone_password`, `operator_password`, `admin_token`, `notifier_token` |
| `dokploy` | `url` (public panel), `local_api_url` | `api_key` |
| `dontstarve` | — | `cluster_token`, `server_password` (re-seed the host token files after reboot) |

Fill secret fields from the corresponding root-only host files
(`/etc/ntfy/credentials.env`, `/root/.config/pi/dokploy.env`) directly in the
1Password application; agents never copy values between file and vault.

## Reference form

Use stable item and field names:

```dotenv
ANTHROPIC_API_KEY=op://Workstation/Pi/anthropic_api_key
```

Consume references without exposing resolved values:

```bash
op run --env-file ~/.config/workstation/secrets.env -- pi
```

No consumer-specific secret reference is managed until its item schema and
launch path are deliberately added.
