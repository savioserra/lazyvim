# workstation subagents service spike

This is the repository's sole nested Go module. It is not the retired workstation CLI and must not grow repository apply/update commands or a Makefile.

- GoAkt v4.5.2 actors live directly under `internal/actors`; there is no actor wrapper. A supervised persistence effect actor fsyncs bounded hosted operational state before mutation receipts.
- `api/subagents/v1/subagents.proto` is canonical. `subagents.pb.go` and `subagents_pb.ts` are generated together and are not hand-edited.
- UDS framing is the cross-language application protocol. GoAkt remoting remains a separate, optional TCP concern.
- Global AgentActors outlive ephemeral client sessions. Existing `pi-subagents` runs retain typed observed-upstream authority; separately typed hosted-owned agents never dual-bind to upstream execution.
- The foreground daemon exposes a bounded hosted admin operation only when separately enabled. A generated owner-private admin credential authenticates START/STATUS/STOP; START securely creates the bridge session credential/config and returns no secrets. An explicit hosted-owned registration then gives an AgentActor one DeathWatch-observed `HostedPiRuntimeActor` and one full persistent Pi TUI in an exactly owned tmux session. The runtime uses argv-only tmux/Pi invocation, a dedicated Pi session directory/name, documented bridge APIs, tmux-server PID/start-token, captured stable session/window/pane IDs, and exact pane process identity, and normal tmux attach. Repository service and hosted-Pi configuration are enabled by managed owner policy.
- `home/dot_pi/private_agent/extensions/hosted-pi-bridge/` is inert outside an exact hosted environment. It exposes list/resolve/send/ask/typed-control/subscribe/unsubscribe commands and tools over authenticated bounded protobuf UDS traffic; ordinary delivery is notification-only, asks wait for typed delivery acknowledgement, per-authenticated-source session/generation/principal/fence/incarnation mutation high-waters and transport-reconciled exact retries that retain unresolved identity across invocation exhaustion rejects all retired replay while retaining a bounded recent result cache, readiness is a renewable fenced lease, model tools require explicit targets, and terminal input/output is never transport.
- The command can run in the foreground for tests, and chezmoi setup builds it to `~/.local/bin/workstation-subagents` and enables/starts the owner systemd-user service or LaunchAgent. Managed service and hosted actor gates are true. Remoting remains disabled until host-specific trusted-network policy and owner-private URI-SAN mTLS material exist. Schema-v2 enabled remoting binds three GoAkt cluster listeners only to the concrete local trusted-network IPv4 address, re-resolves configured DNS peers during bootstrap/rejoin, requires two-replica write quorum with automatic relocation disabled, and installs `actor.WithRemote`/`actor.WithCluster` only after validation.

## Reproducible generation

`tools/codegen.sh` does not resolve generators from ambient `PATH`. It downloads protoc 33.5 for the supported build host and verifies the platform-specific SHA-256, builds module-locked `protoc-gen-go` 1.36.12, and invokes the exact lockfile-installed `@bufbuild/protoc-gen-es` 2.11.0. The script installs the locked npm generator into a temporary prefix, generates into a temporary directory, byte-compares canonical Go/TypeScript plus the bridge-local TypeScript copy in verification mode, and never creates or changes module-root `node_modules`.

```bash
./tools/codegen.sh verify
./tools/codegen.sh regenerate  # only when intentionally changing the schema
```

Supported generation hosts are Linux x86-64, macOS arm64, and macOS x86-64. The CI verification runs without ambient generator lookup.

## Validation

```bash
npm ci --ignore-scripts --no-audit --no-fund
go test -race ./...
go vet ./...
npm test
RUN_REAL_HOSTED_PI_SMOKE=1 go test ./internal/service -run '^(TestRealInstalledPiHostedBridgeIsolatedTmuxSmoke|TestRealDaemonCrashRestartAdoptsHostedPiAndDurableDelivery)$' -count=1 -v
GOOS=darwin GOARCH=arm64 go build -o "$(mktemp)" ./cmd/subagents
```

The golden test uses the exact lockfile runtime (`tsx` plus `@bufbuild/protobuf`) to execute the generated TypeScript descriptor, construct and deterministically encode the fixture, frame it, decode the Go-produced frame, assert every field, and compare Go/TypeScript bytes.
