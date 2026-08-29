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

The daemon is an owner-local managed capability for ordinary globally discovered Pi. Existing upstream `pi-subagents` runs keep their execution, children, worktrees, recovery, receipts, controls, and projections. Separately typed hosted-owned AgentActors run their own Pi TUI through the owner-private, admin-credential-authenticated bootstrap operation enabled by the managed configuration. Chezmoi setup builds the reviewed daemon/client executables into `~/.local/bin` from the nested source module and enables/starts only the owner user service; it does not use root, OS package managers, launcher scripts, tmux client transport, polling, or unpinned downloads.

```text
ServiceGuardian (global, one ActorSystem)
├── AgentRegistryActor
│   └── AgentActor [stable opaque identity; zero or more sessions]
└── SessionRegistryActor [ephemeral credentials/access only]
```

AgentActors are not children of Pi session lifetimes. The target AgentActor mailbox gives concurrent callers one deterministic command order, reported by a per-agent monotonic command sequence, and request IDs deduplicate repeats. Handles are capability-scoped and fenced. Application projections use GoAkt TopicActor subscriptions and publication IDs rather than a domain subscriber map or sorted fanout. Disconnect removes only session credentials, handles, subscriptions, and views. Stable AgentActors retain explicit lifecycle revision, role/display metadata, passivation/retention, authority-binding scope, and recovery-policy metadata and may be reused by a later authorized session. Hosted-owned fields are serialized through supervised GoAkt effect actors into bounded owner-private durable operational state; BridgeSessionActors own daemon push replay after durable commit, and PersistenceSupervisor quarantines indeterminate state fail-closed. Observed-upstream/XState state remains authoritative and unchanged.

`AuthorityBinding` is either an observed-upstream run ID or a hosted-owned runtime ID; registration rejects empty, mixed, or mismatched bindings. Observed-upstream registration starts nothing and preserves `pi-subagents` authority. Hosted-owned registration creates an AgentActor child `HostedPiRuntimeActor`, watches it with DeathWatch, and publishes only lifecycle/ownership fields that have been measured.

The runtime launches one persistent full Pi TUI with argv-only tmux/Pi arguments, `--tui-mode fullscreen` so Pi owns transcript navigation and scrolling, stable captured tmux session/window/pane IDs plus a stable session name, dedicated Pi session directory/name, normal Pi resources under an explicit project-trust choice, and the repository-managed bridge passed with `-e`. It records tmux-server PID/start-token, stable session/window/pane IDs, pane PID/start-token, and TTY before readiness. Cleanup uses one tmux client connection and one server-serialized `if-shell -F` queue whose ownership predicate immediately guards the exact server/session/window/pane/process markers before killing by stable session ID; a disappeared server or same-name replacement fails closed. Startup rollback uses the same atomic predicate. It never uses shell command strings, `send-keys`, `respawn-pane`, stdin control, or terminal scraping. Versioned bounded 0600 XDG-state registration and exact ownership records prevent blind duplicate startup and retain session/fence/mutation/delivery state. Successful tmux creation with malformed identity output retains a partial degraded record plus reservation as ownership-indeterminate. If atomic publication reports failure after rename, the held reservation permits exact-record comparison; only exact tmux rollback followed by exact record removal and directory sync makes failure definitive, while any uncertainty retains the reservation. On restart the daemon securely enumerates durable registrations, validates credential and configured path roots, verifies exact tmux/process tokens and markers, and adopts the same owned Pi process without launching a duplicate. Managed daemon shutdown first persists bridge readiness as false and publishes the resulting reconnecting projection, but leaves exactly owned tmux/Pi processes alive for adoption; explicit actor STOP remains the destructive cleanup path. The systemd unit signals only the daemon process, and the LaunchAgent abandons the child process group, so the service manager cannot race exact ownership handling by killing the tmux server. Proven absence permits stale cleanup; foreign or indeterminate identity remains degraded and untouched. Each public-agent topic snapshot starts with an epoch/sequence-fenced reset before its upserts, removing stale remote actors that are absent after reconciliation instead of retaining an old ready projection.

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
| Runtime | Advertised workstation actor WebSocket endpoint, default port `17213`, plus owner-private admin credential file |
| State | `$XDG_STATE_HOME/workstation/subagents/`; `registrations/` contains bounded atomic 0600 operational records under 0700 no-follow directories |
| Hosted bridge | `home/dot_pi/private_agent/extensions/hosted-pi-bridge/` |
| Lifecycle owner | `home/dot_local/share/workstation/packages/subagents/` |

When the separately reviewed `[hosted_pi].enabled` gate is true, daemon startup creates an owner-private admin credential file named by configuration. A caller possessing that credential can invoke bounded START/STATUS/STOP: START creates a fresh runtime-scoped authenticated session and 0600 bridge credential file, derives the runtime IDs and tmux names, registers/starts the owned agent, and returns only stable nonsecret runtime/attach metadata; STATUS and STOP require the same admin credential. The hosted session has no wall-clock extension race: it remains valid only for that runtime generation and is explicitly revoked with credential removal during exact STOP/stale cleanup. Operations serialize per agent. Registration is an ordered Tell/result protocol rather than an ambiguous Ask. Before every mutating registration Tell, the service publishes a reconciliation placeholder holding the original typed outcome and compensation channels. Timeout enqueues ordered idempotent compensation but returns without abandoning either channel. The persistent watcher can wait beyond caller deadlines, atomically replaces the placeholder with exact agent/runtime PID cleanup state, then acknowledges tracking so the registry may release its retained compensation outcome. Service shutdown waits placeholders before cleanup, persists hosted runtime projection quiescence, and cannot stop ActorSystem while external runtime identity is unresolved. Definitive failed starts cancel and unregister before credential removal so START can retry, while indeterminate compensation is published as tracked degraded ownership. Exact STOP unregisters and atomically retires the live PID before fallible session/credential cleanup; `cleanup_pending` terminal metadata makes duplicate STOP and daemon shutdown retry only those idempotent steps without messaging a dead PID. The managed source keeps this gate false and contains no credential value.

The catalog contribution installs exact production dependencies for the hosted bridge and actor client, builds `workstation-subagents` plus `workstation-subagents-clientctl` with `go build -mod=readonly`, and activates the owner service. The managed config requires `[service].enabled = true`, `[hosted_pi].enabled = true`, and `[remoting].enabled = false`. Lifecycle verification intentionally parses only the managed TOML subset: bare single-component tables and keys with one-line booleans, decimal integers, basic strings, or basic-string arrays. It rejects duplicate tables/keys, quoted or dotted keys, multiline/literal strings, inline tables, and every other TOML construct; it is not a general TOML parser. Chezmoi manages an active systemd user unit on Linux/WSL and active RunAtLoad LaunchAgent plist on macOS.

## Workstation actor endpoint contract

The daemon serves the application control plane on an advertised workstation actor WebSocket endpoint. Binary messages carry the same four-byte big-endian length-prefixed protobuf envelope capped at 64 KiB, and unknown major versions fail closed. The endpoint is selected from managed configuration by ordinary clients and can be changed explicitly with `/actor-connect <node|host|ws://host:port/actors>`. Possessing an endpoint is not authority: every request still carries an authenticated session/admin credential, deadline, request ID, sequence, and fence as applicable. Shutdown atomically rejects new admission, closes the listener/connections, cancels and boundedly waits for in-flight hosted operations, then snapshots/stops every published runtime before stopping the ActorSystem.

Health, list, resolve, attach/reattach/detach, tell, typed abort/shutdown control, subscribe/unsubscribe, bridge lifecycle, delivery acknowledgement, owner-private server-push frames, bounded compatibility polling, and the separately admin-authenticated hosted bootstrap/status/stop operation share one bounded protobuf envelope. Every request carries caller/session identity, immutable generation, credential, request ID, absolute deadline, connection sequence, and fence as applicable. Actor-message mode is validated and mapped to `send` or `ask` server-side; source identity is derived from the authenticated hosted principal, while the current target handle/fence is mandatory. Typed abort and shutdown use distinct `control_abort` and `control_shutdown` capabilities and cannot be selected by ordinary bytes. Each connection enforces bounded sequence advance and a 256-response replay window; same-sequence payload collisions and out-of-window replay fail closed. Resolution accepts exact IDs and unique prefixes; ambiguity returns sorted candidates rather than choosing.

The hosted bridge registers `/actor-list`, `/actor-resolve`, `/actor-health`, `/actor-tell`, `/actor-abort`, `/actor-shutdown`, `/actor-subscribe`, and `/actor-unsubscribe` plus equivalent underscore-named model tools only inside an authenticated hosted runtime. Human commands may omit a target for self; every target-bearing model tool requires an explicit target. It reports `session_start`, readiness, and `session_shutdown`, continuously reads the authenticated WebSocket stream, demultiplexes replies from unsolicited push deliveries/lifecycle transitions, and explicitly acknowledges each typed delivery. `/actor-tell` enqueues a prompt delivery and returns an admission receipt immediately instead of blocking the caller. Only typed, separately authorized controls call documented `ctx.abort()` or `ctx.shutdown()`. Every message/control mutation carries a positive source mutation sequence scoped server-side to the exact authenticated source tuple `(session, generation, principal, target fence, hosted incarnation)` and must advance by exactly one after an admitted result. Authorization precedes replay handling. Each source scope owns its immutable high-water, bounded 1024-result cache, dedupe map, active chains, and ask waiters: retained exact retry returns its result (or reattaches the current pending waiter), collision fails, and old/evicted sequence never reexecutes. Different sources may use the same sequence/dedupe/chain IDs without interference. Pending entries reference their source scope in the global delivery queue, survive another source's mutation or fence rotation, and remain until ACK/deadline even after source revocation; revocation denies future replay first. At most 256 deliveries remain outstanding globally. Same-source reconnect preserves scope; explicit fenced replacement creates only that source's new scope. Notification and typed-control chains retire after ACK/expiry, while in-use chains reject reuse; high-volume completion remains bounded by source high-water/results. The bridge pins the nonempty Pi session ID and reconnects the same ID without fence rotation. Pi serializes mutations per target handle/fence/incarnation and durably retains at most one unresolved complete logical request (source sequence, request/dedupe/chain IDs, target, payload/control) in memory until a determinate response. Foreground retry exhaustion cannot replace it: a later command first boundedly reconciles that exact immutable request, then allocates the next sequence. Pre-write, write, response-loss, timeout, malformed/correlation, and disconnect failures destroy the connection; reconnect exhaustion is per invocation with cooldown and never terminally latched. Only admitted results advance local high-water. Old unresolved scope may retire on fence change only after explicit old-authorization revocation proof. Connect, lifecycle readiness, push replay, and bounded compatibility poll renew a fenced one-second readiness lease; lease expiry rejects new delivery even while Pi remains alive, and same-session reconnect restores a previously declared-ready lease from the client's last delivery ACK. BridgeSessionActor push uses an ACK-gated delivery cursor: enqueueing a push frame does not retire unacknowledged deliveries, so reconnect may redeliver duplicates until the typed ACK commits. Event polling requires an active TopicActor-acknowledged subscription; nonzero replay cursors are rejected.

The ordinary globally discovered actor client extension registers `/actor-connect`, `/actor-list`, `/actor-resolve`, `/actor-health`, `/actor-tell`, `/actor-create`, `/actor-abort`, `/actor-shutdown`, `/actor-subscribe`, and `/actor-unsubscribe` plus typed `actor_*` model tools with no client-specific environment. `/actor-health` is the ping-with-details surface. `/actor-tell` returns actor-message admission receipts immediately. On `session_start` it discovers the managed actor endpoint and owner-private admin credential, validates credential ownership and permissions, then waits boundedly for readiness. Reconnects are bounded per invocation and never reveal credential material in model output.

Task prompts are distinct typed deliveries. The hosted bridge visibly notifies `source → target kind`, prompts before forwarding, injects them with documented `pi.sendUserMessage`, correlates the bounded assistant answer from `agent_end`, and acknowledges exactly that delivery. One task prompt is admitted per target at a time; chain and hop provenance is inherited by model-initiated actor tools. No terminal input or scraping is used.

## Trusted-network remoting and clustering

GoAkt's actor plane remains separate from the workstation WebSocket application plane. Schema-v2 remoting is disabled by default and may be enabled only for owner-controlled service nodes after the operator-provided trusted network and owner-private URI-SAN mTLS material are provisioned. `port` is the GoAkt actor endpoint; the workstation application endpoint uses `actor_endpoint_port`; clustering additionally requires distinct discovery/gossip and peers/registry ports.

Example only (certificate paths are references, never repository content):

```toml
schema_version = 2

[remoting]
enabled = true
mode = "cluster"
network_trust = "private-overlay"
cluster_name = "workstation"
node_identity = "node-a"
bind_host = "peer-a.example.internal"
dns_suffix = ".example.internal"
port = 17210
discovery_port = 17211
peers_port = 17212
allowed_cidrs = ["10.0.0.0/8"]
address_families = ["ipv4"]
mtls_identity = "spiffe://workstation/subagents/node-a"
ca_file = "/owner/private/remoting/ca.pem"
cert_file = "/owner/private/remoting/node-a.pem"
key_file = "/owner/private/remoting/node-a.key"

[[remoting.peers]]
node_identity = "node-b"
host = "peer-b.example.internal"
mtls_identity = "spiffe://workstation/subagents/node-b"

[[remoting.peers]]
node_identity = "node-c"
host = "peer-c.example.internal"
mtls_identity = "spiffe://workstation/subagents/node-c"
```

The validator requires exactly two peers for the managed topology, configured trusted-network CIDRs/address families, a full host beneath the declared DNS suffix, one concrete locally assigned bind answer, distinct unprivileged ports, unique logical/mTLS identities, and 0600 certificate files beneath a descriptor-walked owner-private 0700 directory. Mixed valid/poisoned DNS answers fail as a unit. The discovery provider resolves every peer again on each bootstrap/rejoin request. TLS 1.3 verifies complete chains and exactly one allowlisted URI SAN in both directions.

The operator-provided private network is the approved reachability boundary; mTLS is an independent actor-plane allowlist. GoAkt v4.5.2 cannot bind one URI SAN to one source IP, so every configured peer is equally trusted. The initial topology lists three nodes, keeps two replicas, requires both replicas for writes, and allows reads from one; a node needs at least one peer to bootstrap. An isolated node therefore cannot accept cluster-registry writes. Automatic actor relocation is disabled: DNS changes and node loss cannot migrate a hosted actor's durable home authority. Public cross-node hosted AgentActor placement is explicitly typed: `HostedAdminRequest.target_node` is optional and empty preserves local creation; a non-empty logical node routes over the GoAkt actor plane to that node's local placement authority with bounded operation ID, deadline, dedupe identity, local leaf certificate chain, and a signature over a canonical versioned placement envelope; the remote authority verifies the chain against its configured CA, exact allowlisted peer URI SAN, intended target node, signature, deadline, and replay/collision ledger before side effects, with no admin credential; the authority relies on the equally-trusted mTLS peer boundary before starting the normal hosted AgentActor aggregate, local hosted Pi runtime, and bridge. Each node-local authority also serves a typed public hosted-agent list derived from its local registry; ordinary WebSocket list/resolve/Tell/Ask/prompt paths reconcile that bounded projection from peers and route by stable ID after authorization; private actors are excluded, stale home nodes fail deterministically, and public responses do not expose host/port or actor-plane internals. Non-protobuf actor-plane messages use an explicit append-only CBOR serializer registry. Managed configuration remains off until certificates and physical multi-node validation are complete.

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

Scratch apply / env-free normal-Pi E2E strategy:

1. Use a disposable HOME/destination and a disposable user-service boundary (container or VM preferred so service activation cannot affect the operator session), then run `chezmoi --source <repo> --destination <scratch-home> apply` from the repository checkout.
2. Assert `~/.local/bin/workstation-subagents` and `~/.local/bin/workstation-subagents-clientctl` are 0700 owner binaries, the managed config is 0600 under 0700 directories, the systemd-user unit or LaunchAgent is enabled/started, and the daemon endpoint/admin credential are owner-private with no symlink components.
3. Start a fresh ordinary global `pi` with only HOME/XDG standard variables (no client-specific actor environment and no `-e` launcher), then verify `/actor-list` and the `actor_list` tool are present.
4. Run `/actor-create e2e-worker -- <absolute scratch worktree> -- E2E Worker -- reviewer`, `/actor-tell e2e-worker -- Reply exactly E2E_OK`, and confirm the immediate correlated admission receipt has no secret/credential path output. Restart Pi and repeat `/actor-list`, `/actor-health e2e-worker`, and one `/actor-tell e2e-worker -- brief acknowledgement` to prove bounded reconnect/readiness.

## Platform lifecycle

Native Windows is unsupported; use WSL, which follows the Linux systemd-user, `/proc`, XDG, tmux, and workstation endpoint paths. The native-Windows CI job, PowerShell apply harness, and Windows apply script have been retired after extraction of the Linux/macOS shell checks. Remaining cross-platform tool templates are not a supported native-Windows lifecycle.
