---
name: secrets
description: Safely manages this workstation's secret references and explicitly approved 1Password metadata or mutations in the dedicated LazyVIM vault. Use only when the user invokes /skill:secrets.
compatibility: Requires the 1Password CLI and an authenticated account with access to the LazyVIM vault.
disable-model-invocation: true
---

# Secrets

Use only the 1Password vault named `LazyVIM`. This skill is a handling policy, not a permission boundary.

## Start

1. Confirm `op --version` succeeds.
2. Confirm authentication with `op whoami` without printing account details.
3. Confirm `op vault get LazyVIM` succeeds without displaying its JSON.
4. If any check fails, stop and ask the user to unlock 1Password or enable desktop CLI integration. Do not start an interactive sign-in flow.

Never enumerate, inspect, or modify another vault. Desktop CLI authentication may technically grant broader access, but that access is out of scope.

## Default workflow

1. Ask what application, item, and field schema the user intends to manage.
2. Prefer stable `op://LazyVIM/<item>/<field>` references in chezmoi source.
3. Prefer `op run` or `op inject` so values flow directly to the consuming process.
4. Keep normal `chezmoi apply`, tests, and verification independent of vault authentication.
5. Inspect only titles, field labels, categories, and other non-secret metadata when diagnosing schema.

## Secret-value boundary

- Never retrieve an existing password, token, private key, credential, or recovery value into model context.
- Never print secret values, include them in tool results, or ask the user to paste them into chat.
- Never place secret values in command arguments, Git, chezmoi source, patches, logs, session files, or temporary files.
- Never expose `OP_SERVICE_ACCOUNT_TOKEN` or any 1Password session token.
- If an operation cannot be completed without exposing a value through the available tools, ask the user to complete that step in the 1Password application.

## Mutations

Creating, editing, archiving, or deleting an item requires explicit user approval for the exact operation and item. Approval for one mutation does not authorize another.

Before a mutation:

1. State the target as `LazyVIM/<item>`.
2. List field labels and types, never values.
3. Explain whether the operation creates, replaces, archives, or deletes data.
4. Wait for confirmation.

Prefer creating an item schema without secret values and having the user populate sensitive fields in the 1Password application. Never overwrite or delete an existing item merely to reconcile naming.

## Repository integration

Commit only references and non-secret schema. A reference file may contain entries such as:

```dotenv
ANTHROPIC_API_KEY=op://LazyVIM/Pi/anthropic_api_key
```

Do not make the `secrets` lifecycle capability verify authentication or vault contents. It verifies the managed 1Password CLI only; interactive account state remains host-owned.
