# pi-ntfy-notifier

A Pi package extension that sends an [ntfy](https://ntfy.sh) notification after an agent run has fully settled.

It uses Pi's `agent_settled` lifecycle event, so it waits until retries, compaction retries, and queued follow-ups are finished. The final assistant response is classified as either:

- **Pi completed — agent-name** — default priority with a completion tag
- **Pi needs attention — agent-name** — high priority when the response asks for input, is blocked, or ends with an error/abort/length stop reason

The title identifies the Pi session or sub-agent by its session name, falling back to the working directory name. Interactive and process-isolated `pi-subagentura` agents set their agent name as the Pi session name, so simultaneous agent notifications remain distinguishable.

The assistant response itself is never sent to ntfy. Notifications contain only a generic status and elapsed time by default.

The package has no built-in server or topic: it publishes nothing until `PI_NTFY_SERVER` and `PI_NTFY_TOPIC` are provided by the host environment, so no infrastructure details are baked into the code.

## Install

```bash
pi install /path/to/pi-ntfy-notifier
```

Start a new Pi process or run `/reload` in an existing Pi TUI after installation.

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
export PI_NTFY_TOKEN=tk_your_token
pi
```

Keep topic names generic (`pi`, `backups`, `alerts`) and rely on server-side access control (`auth-default-access: deny-all` plus per-user/token grants) instead of unguessable topic names. On public shared servers without access control, a topic name effectively acts as a password.

## Development

```bash
npm test
npm run pack:check
pi --no-extensions -e ./extensions/ntfy-notifier.ts --list-models
```
