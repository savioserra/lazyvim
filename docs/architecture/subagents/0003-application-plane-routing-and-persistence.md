# ADR 0003: Application plane, actor routing, peer identity, and persistence

- **Status:** Accepted
- **Scope:** Pi bridge API, transport separation, deployment identity, diagnostics, and recovery

## Context

Pi tools need list/resolve/send/ask/subscribe behavior without learning transport PIDs. Local UDS clients and future GoAkt peers have different protocols and trust boundaries. Reusable agents also require clear persistence and diagnostic guarantees before hosted execution can become authoritative.

## Decision

The approved visual and interaction contract for actor communication is the [Actor UX design system](ACTOR-UX-DESIGN-SYSTEM.md).

### Pi-to-actor path

Pi calls the repository-managed hosted bridge extension over an owner-private UDS. The bridge binds exactly one runtime ID/incarnation and Pi session to one authenticated AgentActor handle/fence. The registry validates the current session instance, generation, credential, caller, capability, deadline, and target before resolving the actor with `ActorOf`. The gateway then uses direct GoAkt Tell/Ask semantics. An omitted public target is normalized by the bridge to its hosting AgentActor.

Public targets are stable logical agent IDs or opaque capability handles, never raw PIDs. The registry maps a logical agent to its durable home node; public routing checks session credential/capability before any actor lookup, excludes private actors from public discovery, rejects stale home nodes, and then uses GoAkt remote lookup/Tell/Ask against the recorded endpoint. Typed remote hosted placement uses an optional logical target node on the canonical hosted-admin protobuf request. The local daemon authenticates the admin request, routes a typed actor-plane placement command carrying bounded operation ID, deadline, dedupe identity, local leaf certificate chain, and a signature over a canonical versioned placement envelope; the remote authority verifies the chain against its configured CA, exact allowlisted peer URI SAN, intended target node, signature, deadline, and replay/collision ledger before side effects, with no admin credential to the target node's local authority, and that authority relies on the equally-trusted mTLS peer boundary before starting the existing hosted AgentActor aggregate with its local hosted Pi runtime and bridge; no SSH, shell, tmux transport, terminal scraping, dependency-free echo actor, or actor relocation is involved. Requests carry a typed payload, request ID, absolute deadline, required capability, mutation operation identity, hop limit, and dedupe identity. Hop limits prevent bridge/routing loops. Node-local authorities expose a typed public hosted-agent list from their local registry so peers can reconcile public home-node records on startup and resolve/list misses without persisting host/port in the client API. Ask responses are typed success/failure values. Pi TUI commands and model/tool calls receive ordinary typed tool responses; the bridge does not synthesize terminal input.

Subscriptions are authorized projection requests. Projection actors use GoAkt TopicActor Subscribe/Unsubscribe and receive published domain events. Subscription success follows native `SubscribeAck`; close retries through the GoAkt scheduler, waits for native `UnsubscribeAck`, and uses DeathWatch termination as the AgentActor's teardown proof. PubSub IDs suppress redelivery within GoAkt's retention window; mutation identity ledgers remain fail-closed beyond bounded result retention.

Bridge connections use the same bounded envelope sequence, response replay, deadline, credential, and fence rules as local clients. Poll responses provide bounded pages for sanitized projection events and retained daemon-to-Pi deliveries; the cursor is the last emitted sequence and deliveries remain until explicit typed acknowledgement. Delivery carries authenticated source, target, request, absolute deadline, dedupe and chain identity, remaining hop count, and typed notification/control kind. Ordinary delivery uses documented UI notification only and cannot start a model turn; separately authorized typed control intents use documented `abort` and `shutdown` methods. It never logs credentials, prompts, model output, or raw payloads.

### Two protocol planes

The length-framed protobuf UDS API is the application plane for Pi/TypeScript and local clients. GoAkt remoting is the actor plane for ActorOf, Tell/Ask, PubSub dissemination, DeathWatch, supervision support, and optional reliable delivery. Neither plane tunnels or re-encodes the other. Protobuf never exposes GoAkt implementation values.

### Peer configuration

Schema v2 supports an explicit three-node GoAkt cluster over Tailscale. The custom advertised actor port, discovery/gossip port, and peers/registry port are distinct fixed listeners bound only to the concrete local Tailscale IPv4 address. A repository-owned discovery provider re-resolves configured MagicDNS peers during bootstrap and quorum-loss rejoin. DNS supplies candidate addresses only: DNS names are neither logical node identity nor mTLS identity.

Tailscale ACL/device identity is the network trust boundary. Independent TLS 1.3 mutual authentication requires an exact allowlist of peer URI SAN identities and owner-private, no-follow certificate material. GoAkt v4.5.2 cannot bind one certificate identity to one source IP; the accepted deployment treats all allowlisted service nodes as equally trusted actor-plane peers. Automatic actor relocation remains disabled, and DNS changes never migrate durable home-node authority.

### Persistence and diagnostics

Hosted-owned registrations persist schema-versioned operational state beneath XDG state: logical/authority identity, capabilities, retention/recovery policy, credential-file reference, session generation, runtime configuration, exact tmux/process binding, attachment/fence, source mutation high-water/recent results, and pending delivery payloads needed to honor accepted work. This state is separately classified from diagnostics, bounded to 4096 records and 1 MiB each, atomically replaced and directory-fsynced at 0600 beneath descriptor-walked 0700 owner-private directories. A supervised GoAkt effect actor performs fsync asynchronously and returns typed completions; mutation receipts wait for completion while AgentActor Receive stays nonblocking. Failure rolls back admission fail-closed. Restart validates records and configured path roots, reopens the same session generation/credential, and adopts only exact live tmux and process tokens/markers. Proven absence permits fsynced stale cleanup; foreign or indeterminate identity is neither killed nor duplicated.

Diagnostics are append-oriented, bounded, redacted, and monotonic. They distinguish application projection events from ActorSystem event-stream lifecycle/deadletters. Credentials, opaque handles, request payload secrets, raw model context, and personal deployment examples are not diagnostic dimensions. Health reports durable degradation instead of silently claiming readiness.

## Consequences

Clients can move between local or authenticated remote agents without API PID coupling. Hosted execution survives client and daemon loss when exact durable ownership can be revalidated; indeterminate external identity remains degraded.

## Invariants

- Authorization precedes lookup, routing, cached-result return, and projection subscription.
- Session ID and generation are globally single-use within the capped identity ledger; full ledgers reject new identities.
- Evicted mutation results leave tombstones and are never executed again.
- Home-node changes are durable, monotonic migrations; DNS changes alone cannot move authority.
- Expiry uses the same acknowledged cleanup coordinator as explicit close.
- Cleanup plans remain until both registries and every affected live AgentActor acknowledge or DeathWatch proves termination; an AgentActor with a projection retains its acknowledgement until projection unsubscribe and termination are proven.
- Global AgentActors survive session and view cleanup.
- Managed configuration keeps remoting disabled until host-specific Tailscale ACLs and URI-SAN mTLS files are provisioned. Enabled schema-v2 configuration installs `WithRemote`, `WithCluster`, and `WithoutRelocation` only after strict Tailscale DNS/address and certificate validation.
