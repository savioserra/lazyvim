# Secrets reference

## Components

| Component | Contract |
| --- | --- |
| `secrets` capability | Verify the pinned 1Password CLI; do not inspect authentication or vault state |
| `LazyVIM` vault | Dedicated scope for this workstation's secrets |
| `/skill:secrets` | Explicit-only policy for safe metadata, references, and approved mutations |
| Chezmoi source | Store `op://` references and non-secret schema only |

The capability name describes the workstation concern; 1Password is its current
backend. The desktop application, account session, and vault contents remain
host-owned mutable state.

## Boundaries

- Normal apply, sync, verify, and CI never require vault authentication.
- Never commit or render secret values into persistent configuration.
- Prefer `op run` or `op inject` over retrieving values into agent context.
- Scope every operation to the `LazyVIM` vault.
- Require explicit user approval for each create, edit, archive, or delete.
- Use a vault-scoped service account when technical enforcement is required on a headless host.

Desktop CLI setup:

```text
Unlock 1Password
  -> Settings > Developer > Integrate with 1Password CLI
  -> op whoami
```

## Reference form

Use stable item and field names:

```dotenv
ANTHROPIC_API_KEY=op://LazyVIM/Pi/anthropic_api_key
```

Consume references without exposing resolved values:

```bash
op run --env-file ~/.config/lazyvim/secrets.env -- pi
```

No consumer-specific secret reference is managed until its item schema and
launch path are deliberately added.
