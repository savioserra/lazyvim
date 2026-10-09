# pi-ntfy-notifier

A Pi package extension that sends an [ntfy](https://ntfy.sh) notification after an agent run has fully settled.

It uses Pi's `agent_settled` lifecycle event, so it waits until retries, compaction retries, and queued follow-ups are finished. The final assistant response is classified as either:

- **Pi completed — agent-name** — default priority with a completion tag
- **Pi needs attention — agent-name** — high priority when the response asks for input, is blocked, or ends with an error/abort/length stop reason

The title identifies the Pi session by its session name, falling back to the working directory name.

The assistant response itself is never sent to ntfy. Notifications contain only a generic status and elapsed time by default.

The package has no built-in server or topic: it publishes nothing until `PI_NTFY_SERVER` and `PI_NTFY_TOPIC` are provided by the host environment, so no infrastructure details are baked into the code.

## Apply and reload

This repository deploys the source-managed extension to
`~/.pi/agent/extensions/ntfy-notifier` through `workstation apply`.
Start a new Pi process or run `/reload` in the existing Pi TUI after applying;
no separate `pi install` is needed.

## Commands

```text
/ntfy-test complete
/ntfy-test action
/ntfy-status
```

## Configuration

Set environment variables before starting Pi. With no `PI_NTFY_SERVER`/`PI_NTFY_TOPIC` the notifier stays silent.

| Variable | Default | Purpose |
|---|---|---|
| `PI_NTFY_SERVER` | *(required)* | ntfy server base URL; must be `https://` (`http://` allowed only for `localhost`/`127.0.0.1`/`[::1]`) |
| `PI_NTFY_TOPIC` | *(required)* | Destination topic, 1–64 chars of `A-Za-z0-9-_` |
| `PI_NTFY_TOKEN` | unset | Bearer token for servers with access control |
| `PI_NTFY_TIMEOUT_MS` | `5000` | Publish timeout, clamped to 1–30 seconds |
| `PI_NTFY_INCLUDE_CONTEXT` | `false` | Also include hostname and project/session name in the body |

Example:

```bash
export PI_NTFY_SERVER=https://ntfy.example.com
export PI_NTFY_TOPIC=pi
# Supply any required token through the operator-owned environment, never chat or Git.
pi
```

Keep topic names generic (`pi`, `backups`, `alerts`) and rely on server-side access control (`auth-default-access: deny-all` plus per-user/token grants) instead of unguessable topic names. On public shared servers without access control, a topic name effectively acts as a password.

## Verification

The owning workstation package checks manifest/version/files and runs
`node --test test/ntfy.test.mjs`. These unit tests import the extension with a
mock Pi API; they do not exercise real auto-discovery or `/reload`.

Real Pi discovery/reload acceptance remains required for extension changes:
confirm commands/events load once and shutdown/reload cleans up owned resources
without duplicates. Keep credentials out of checks. `/ntfy-test` sends a real
notification and requires separately authorized host configuration; it is not
an offline verification step.
