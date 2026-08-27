# Subagents GoAkt service

Canonical delivery plan and accepted decisions:

- [Actor UX design system](architecture/subagents/ACTOR-UX-DESIGN-SYSTEM.md)
- [Roadmap and phase status](architecture/subagents/ROADMAP.md)
- [ADR 0001: Direct GoAkt domain actors and framework mechanisms](architecture/subagents/0001-direct-goakt-domain-and-lifecycle.md)
- [ADR 0002: Global AgentActor lifetime and hosted Pi execution](architecture/subagents/0002-global-agent-and-hosted-pi-runtime.md)
- [ADR 0003: Application plane, routing, peer identity, and persistence](architecture/subagents/0003-application-plane-routing-and-persistence.md)
- [ADR 0004: Supervisor hierarchy, owned workflow actors, and proposed runtime-owned tmux panel projection](architecture/subagents/0004-supervisor-hierarchy-and-owned-workflows.md)
- [Draft strong TOML workflow-template specification](architecture/subagents/WORKFLOW-TEMPLATE-SPEC.md) and [non-runnable dogfood examples](architecture/subagents/examples/)

## Scope and authority

The daemon remains a source/test capability and does not replace the current `pi-subagents` or XState tmux observer. Existing upstream runs keep their execution, children, worktrees, recovery, receipts, controls, and projections. A separately typed hosted-owned AgentActor can run its own Pi TUI through the owner-private, admin-credential-authenticated bootstrap operation when explicitly enabled, while both `[service].enabled` and `[hosted_pi].enabled` remain false in managed configuration. Nothing under `services/` is installed or started automatically.

```text
ServiceGuardian (global, one ActorSystem)
├── AgentRegistryActor
│   └── AgentActor [stable opaque identity; zero or more sessions]
└── SessionRegistryActor [ephemeral credentials/access only]
```

AgentActors are not children of Pi session lifetimes. The target AgentActor mailbox gives concurrent callers one deterministic command order, reported by a per-agent monotonic command sequence, and request IDs deduplicate repeats. Handles are capability-scoped and fenced. Application projections use GoAkt TopicActor subscriptions and publication IDs rather than a domain subscriber map or sorted fanout. Disconnect removes only session credentials, handles, subscriptions, and views. Stable AgentActors retain explicit lifecycle revision, role/display metadata, passivation/retention, authority-binding scope, and recovery-policy metadata and may be reused by a later authorized session. Hosted-owned fields are serialized through supervised GoAkt effect actors into bounded owner-private durable operational state; BridgeSessionActors own daemon push replay after durable commit, and PersistenceSupervisor quarantines indeterminate state fail-closed. Observed-upstream/XState state remains authoritative and unchanged.

`AuthorityBinding` is either an observed-upstream run ID or a hosted-owned runtime ID; registration rejects empty, mixed, or mismatched bindings. Observed-upstream registration starts nothing and preserves `pi-subagents` authority. Hosted-owned registration creates an AgentActor child `HostedPiRuntimeActor`, watches it with DeathWatch, and publishes only lifecycle/ownership fields that have been measured.

The runtime launches one persistent full Pi TUI with argv-only tmux/Pi arguments, `--tui-mode fullscreen` so Pi owns transcript navigation and scrolling, stable captured tmux session/window/pane IDs plus a stable session name, dedicated Pi session directory/name, normal Pi resources under an explicit project-trust choice, and the repository-managed bridge passed with `-e`. It records tmux-server PID/start-token, stable session/window/pane IDs, pane PID/start-token, and TTY before readiness. Cleanup uses one tmux client connection and one server-serialized `if-shell -F` queue whose ownership predicate immediately guards the exact server/session/window/pane/process markers before killing by stable session ID; a disappeared server or same-name replacement fails closed. Startup rollback uses the same atomic predicate. It never uses shell command strings, `send-keys`, `respawn-pane`, stdin control, or terminal scraping. Versioned bounded 0600 XDG-state registration and exact ownership records prevent blind duplicate startup and retain session/fence/mutation/delivery state. Successful tmux creation with malformed identity output retains a partial degraded record plus reservation as ownership-indeterminate. If atomic publication reports failure after rename, the held reservation permits exact-record comparison; only exact tmux rollback followed by exact record removal and directory sync makes failure definitive, while any uncertainty retains the reservation. On restart the daemon securely enumerates durable registrations, validates credential and configured path roots, verifies exact tmux/process tokens and markers, and adopts the same owned Pi process without launching a duplicate. Proven absence permits stale cleanup; foreign or indeterminate identity remains degraded and untouched.

## Paths and lifecycle

| Concern | Path/contract |
| --- | --- |
| Nested module | `services/subagents/go.mod` |
| Command | `services/subagents/cmd/subagents` |
| Direct domain actors | `services/subagents/internal/actors/` |
| Canonical schema | `services/subagents/api/subagents/v1/subagents.proto` |
| Generated Go/TypeScript | Same API directory; generated files are not hand-edited |
| Golden fixtures | `services/subagents/testdata/golden/` |
| Repository config source | `home/dot_config/private_workstation/private_subagents/private_config.toml.tmpl` |
| Deployed config | `~/.config/workstation/subagents/config.toml`, 0600 under 0700 directories |
| Runtime | `$XDG_RUNTIME_DIR/ws-subagents/control.sock`, with an owner-private short temp fallback when XDG runtime is unset |
| State | `$XDG_STATE_HOME/workstation/subagents/`; `registrations/` contains bounded atomic 0600 operational records under 0700 no-follow directories |
| Hosted bridge | `home/dot_pi/private_agent/extensions/hosted-pi-bridge/` |
| Lifecycle owner | `home/dot_local/share/workstation/packages/subagents/` |

When the separately reviewed `[hosted_pi].enabled` gate is true, daemon startup creates an owner-private admin credential file named by configuration. A caller possessing that credential can invoke bounded START/STATUS/STOP: START creates a fresh runtime-scoped authenticated session and 0600 bridge credential file, derives the runtime IDs and tmux names, registers/starts the owned agent, and returns only stable nonsecret runtime/attach metadata; STATUS and STOP require the same admin credential. The hosted session has no wall-clock extension race: it remains valid only for that runtime generation and is explicitly revoked with credential removal during exact STOP/stale cleanup. Operations serialize per agent. Registration is an ordered Tell/result protocol rather than an ambiguous Ask. Before every mutating registration Tell, the service publishes a reconciliation placeholder holding the original typed outcome and compensation channels. Timeout enqueues ordered idempotent compensation but returns without abandoning either channel. The persistent watcher can wait beyond caller deadlines, atomically replaces the placeholder with exact agent/runtime PID cleanup state, then acknowledges tracking so the registry may release its retained compensation outcome. Service shutdown waits placeholders before cleanup and cannot stop ActorSystem while external runtime identity is unresolved. Definitive failed starts cancel and unregister before credential removal so START can retry, while indeterminate compensation is published as tracked degraded ownership. Exact STOP unregisters and atomically retires the live PID before fallible session/credential cleanup; `cleanup_pending` terminal metadata makes duplicate STOP and daemon shutdown retry only those idempotent steps without messaging a dead PID. The managed source keeps this gate false and contains no credential value.

The catalog contribution installs only the bridge's exact `@bufbuild/protobuf@2.11.0` production dependency and verifies inert Pi discovery. The managed config requires both `[service].enabled = false` and `[hosted_pi].enabled = false`. Lifecycle verification intentionally parses only the managed TOML subset: bare single-component tables and keys with one-line booleans, decimal integers, basic strings, or basic-string arrays. It rejects duplicate tables/keys, quoted or dotted keys, multiline/literal strings, inline tables, and every other TOML construct; it is not a general TOML parser. Chezmoi manages an inactive systemd user unit on Linux/WSL and inactive LaunchAgent plist on macOS. Package lifecycle installs neither daemon binary nor service state and never loads, enables, or starts these assets; activation remains a separate reviewed deployment step. Repository defaults keep both gates false.

## Unix socket contract

The daemon supports Linux, WSL-as-Linux, and macOS Unix sockets. It normalizes XDG, config, and socket inputs to absolute paths before policy checks or filesystem access, then walks every directory component descriptor-relatively with no-follow semantics and rejects intermediate symlinks, non-sockets, foreign ownership, widened modes, `/mnt` private paths, active sockets, missing/unsafe ownership leases, and stale-socket identity changes. Cooperating starts serialize stale isolation, bind, and lease publication under an inode-, owner-, and mode-verified owner-private cross-process lock. A stale socket is removed only after process identity is confirmed dead; permission, process-table, `/proc`, `ps`, and other indeterminate lookup failures fail closed. Socket and lease are isolated and revalidated before removal. Isolation failures leave artifacts in a unique owner-private directory and never rename them back over a concurrent replacement. Directories are 0700, the global socket is 0600, frames are four-byte big-endian length-prefixed protobuf capped at 64 KiB, and unknown major versions fail closed. Shutdown atomically rejects new admission, closes the listener/connections, cancels and boundedly waits for in-flight hosted operations, then snapshots/stops every published runtime before stopping the ActorSystem, and removes only the socket inode created by that daemon.

Health, list, resolve, attach/reattach/detach, send, ask, typed abort/shutdown control, subscribe/unsubscribe, bridge lifecycle, delivery acknowledgement, owner-private server-push frames, bounded compatibility polling, and the separately admin-authenticated hosted bootstrap/status/stop operation share one bounded protobuf envelope. Every request carries caller/session identity, immutable generation, credential, request ID, absolute deadline, connection sequence, and fence as applicable. Actor-message mode is validated and mapped to `send` or `ask` server-side; source identity is derived from the authenticated hosted principal, while the current target handle/fence is mandatory. Typed abort and shutdown use distinct `control_abort` and `control_shutdown` capabilities and cannot be selected by ordinary bytes. Each connection enforces bounded sequence advance and a 256-response replay window; same-sequence payload collisions and out-of-window replay fail closed. Resolution accepts exact IDs and unique prefixes; ambiguity returns sorted candidates rather than choosing.

The bridge registers `/actor-list`, `/actor-resolve`, `/actor-send`, `/actor-ask`, `/actor-abort`, `/actor-shutdown`, `/actor-subscribe`, and `/actor-unsubscribe` plus equivalent underscore-named model tools. Human commands may omit a target for self; every target-bearing model tool requires an explicit target. It reports `session_start`, readiness, and `session_shutdown`, continuously reads the authenticated UDS stream, demultiplexes replies from unsolicited push deliveries/lifecycle transitions, and explicitly acknowledges each typed delivery. Ordinary deliveries are notification-only and never start a model turn; only typed, separately authorized controls call documented `ctx.abort()` or `ctx.shutdown()`. `ask` means delivery acknowledgement, not an LLM answer. Every message/control mutation carries a positive source mutation sequence scoped server-side to the exact authenticated source tuple `(session, generation, principal, target fence, hosted incarnation)` and must advance by exactly one after an admitted result. Authorization precedes replay handling. Each source scope owns its immutable high-water, bounded 1024-result cache, dedupe map, active chains, and ask waiters: retained exact retry returns its result (or reattaches the current pending waiter), collision fails, and old/evicted sequence never reexecutes. Different sources may use the same sequence/dedupe/chain IDs without interference. Pending entries reference their source scope in the global delivery queue, survive another source's mutation or fence rotation, and remain until ACK/deadline even after source revocation; revocation denies future replay first. At most 256 deliveries remain outstanding globally. Same-source reconnect preserves scope; explicit fenced replacement creates only that source's new scope. Notification and typed-control chains retire after ACK/expiry, while in-use chains reject reuse; high-volume completion remains bounded by source high-water/results. The bridge pins the nonempty Pi session ID and reconnects the same ID without fence rotation. Pi serializes mutations per target handle/fence/incarnation and durably retains at most one unresolved complete logical request (source sequence, request/dedupe/chain IDs, target, payload/control) in memory until a determinate response. Foreground retry exhaustion cannot replace it: a later command first boundedly reconciles that exact immutable request, then allocates the next sequence. Pre-write, write, response-loss, timeout, malformed/correlation, and disconnect failures destroy the connection; reconnect exhaustion is per invocation with cooldown and never terminally latched. Only admitted results advance local high-water. Old unresolved scope may retire on fence change only after explicit old-authorization revocation proof. Connect, lifecycle readiness, push replay, and bounded compatibility poll renew a fenced one-second readiness lease; lease expiry rejects new delivery even while Pi remains alive, and same-session reconnect restores a previously declared-ready lease from the client's last delivery ACK. BridgeSessionActor push uses an ACK-gated delivery cursor: enqueueing a push frame does not retire unacknowledged deliveries, so reconnect may redeliver duplicates until the typed ACK commits. Event polling requires an active TopicActor-acknowledged subscription; nonzero replay cursors are rejected. The extension is globally discoverable but registers nothing unless every hosted environment field is present and structurally valid.

## Source-only client lane

The repository-owned client lane is isolated under `/tmp/ws-subagents-client-<uid>` and uses a dedicated tmux server. It does not apply chezmoi state or load a managed service:

```bash
services/subagents/tools/source-client.sh up
services/subagents/tools/source-client.sh client
# In the source-loaded Pi:
/actor-client-create worker-1 -- /absolute/existing/worktree
/actor-client-ask worker-1 -- Implement the next focused task and report the result.
```

Attach to an actor with the exact command returned by `/actor-client-attach worker-1`; its shape is `tmux -L ws-subagents-client-<uid> attach-session -t '<stable-target>'`. Actor IDs are dynamic. A writable worktree may have only one actor owner at a time. `source-client.sh worktree-add /trusted/repository NAME` creates an isolated detached worktree using argv-only Git invocation; otherwise callers must supply an existing absolute non-symlink directory. The regular client bootstrap credential is returned only in memory over the private UDS, expires after 30 minutes, and is explicitly closed on Pi shutdown. Client commands/tools use the `actor-client-*` / `actor_client_*` namespaces and do not replace `pi-subagents` authority.

Task prompts are distinct typed deliveries. The hosted bridge visibly notifies `source → target kind`, prompts before forwarding, injects them with documented `pi.sendUserMessage`, correlates the bounded assistant answer from `agent_end`, and acknowledges exactly that delivery. One task prompt is admitted per target at a time; chain and hop provenance is inherited by model-initiated actor tools. No terminal input or scraping is used.

Source-only Linux end-to-end verification after rebuild confirmed the visible four-pane topology: hosted Pi fullscreen transcript scrolling was active in every hosted inner pane and in the visible project-manager pane, Pi fullscreen PageUp/PageDown transcript bindings remained the default because no keybinding override exists, and cross-actor Ask completed successfully. This is implementation evidence for hosted Pi fullscreen transcript scrolling only; `[actors.panel].mouse_scroll` remains a proposed workflow-template preference.

## Generic optional remoting model

GoAkt remoting is separate custom TCP transport; it is never used for the TypeScript application protocol. Remoting remains disabled by default. Configuration uses generic logical identity, bind host, fixed port, peer host, mTLS identity, CIDR/address-family policy, and optional SSH target. DNS provides candidate addresses only and is never accepted as logical or mTLS identity.

Example only (replace every value for the deployment):

```toml
[remoting]
enabled = true
node_identity = "observer-node-a"
bind_host = "node-a.internal.example"
port = 7210
allowed_cidrs = ["192.0.2.0/24"]
address_families = ["ipv4"]
mtls_identity = "spiffe://example.invalid/workstation/node-a"
ca_file = "/owner/private/remoting/ca.pem"
cert_file = "/owner/private/remoting/node.pem"
key_file = "/owner/private/remoting/node.key"

[[remoting.peers]]
node_identity = "observer-node-b"
host = "node-b.internal.example"
mtls_identity = "spiffe://example.invalid/workstation/node-b"
ssh_target = "operator@relay.internal.example"
```

The validator requires the bind host to resolve to exactly one concrete address that is both allowlisted and assigned locally. Every peer answer must satisfy the selected families and CIDRs; mixed allowed/poisoned answers fail as a unit. `0.0.0.0` is rejected. Logical and mTLS identities must be explicit and unique. `ssh_target` remains one uninterpreted value and no SSH command starts. GoAkt v4.5.2 exposes native TLS configuration, but not an accepted-connection hook that can enforce this design's required inbound CIDR-to-certificate-identity binding. Therefore `remoting.enabled = true` fails daemon startup after policy resolution, `remote.NewConfig` is not constructed, and production contains no `actor.WithRemote`. Remoting stays unavailable until that authorization boundary is enforceable without a bypass.

## Code generation and compatibility

GoAkt is exactly pinned to v4.5.2. The managed Go 1.27.0 toolchain satisfies its Go 1.26 floor. The schema is canonical; generated Go and TypeScript are deterministic artifacts, and codegen byte-verifies the bridge-local TypeScript copy against the canonical generated output. `tools/codegen.sh` verifies a platform SHA-256-pinned protoc 33.5 archive, builds module-locked `protoc-gen-go` 1.36.12, invokes lockfile-installed `@bufbuild/protoc-gen-es` 2.11.0 by explicit path, and byte-compares temporary regeneration outputs. Generated files must be regenerated together and the Go/TypeScript framed golden fixture must remain byte-identical unless an intentional protocol revision updates all consumers.

Major versions are rejected when unknown. Minor-compatible readers accept protobuf unknown fields. GoAkt PIDs, actor paths, serializers, and remoting messages never appear in this API.

Darwin is cross-built and has process-token parsing/cancellation tests, but this change does not claim a physical macOS hosted-Pi runtime smoke; macOS activation requires that platform smoke separately.

## Validation

```bash
cd services/subagents
npm ci --ignore-scripts --no-audit --no-fund
./tools/codegen.sh verify
go test -race ./...
go vet ./...
npm test
RUN_REAL_HOSTED_PI_SMOKE=1 go test ./internal/service -run '^TestRealInstalledPiHostedBridgeIsolatedTmuxSmoke$' -count=1 -v
```

## Platform lifecycle

Native Windows is unsupported; use WSL, which follows the Linux systemd-user, `/proc`, XDG, tmux, and Unix-socket paths. The native-Windows CI job, PowerShell apply harness, and Windows apply script have been retired after extraction of the Linux/macOS shell checks. Remaining cross-platform tool templates are not a supported native-Windows lifecycle.
