// Client-peer mutation sequencing for the regular actor-client extension.
//
// The daemon enforces one source mutation sequence namespace per client peer
// (the terminal AgentActor minted for the client session) across every target:
// an admitted sequence is retained globally for the source agent and any later
// mutation reusing it fails closed with "source mutation sequence collision"
// (and each target additionally validates exactly-one-increase for the
// subsequence it observes). The allocator below therefore uses ONE monotonic
// namespace per client session for actor messages, allocates the next sequence
// only after the previous mutation settled, queues concurrent mutations,
// retains the immutable unresolved mutation across transport failures so a
// reconnect reconciles by replaying the identical logical request (the daemon
// replays the retained admission by request/dedupe/chain/sequence identity —
// this is how the client adopts the server high-water instead of reusing an
// admitted sequence), retries transport failures with a bounded cooldown, and
// fails loud on true sequence collisions instead of silently burning slots.
//
// Control intents (abort/shutdown) keep a per-session per-target namespace
// because the daemon scopes those sequences per (session, target fence). The
// message namespace is keyed by the stable terminal caller identity: reconnects
// and session re-OPENs under the same terminal reattach the same durable
// terminal AgentActor and continue at the high-water, drained completion
// evidence floors a reloaded allocator through adoptHighWater, and scopes
// retire only at session shutdown.

export type ClientMutationAdmission = { accepted: boolean; reason?: string };

const SEQUENCE_FAILURE_REASONS = ["source mutation sequence collision", "source mutation sequence must advance exactly once", "source mutation sequence is at or below the retired high-water mark"] as const;

export function isClientSequenceFailure(reason: unknown): boolean { return typeof reason === "string" && (SEQUENCE_FAILURE_REASONS as readonly string[]).includes(reason); }

export class ClientMutationSequenceError extends Error {
  readonly scopeKey: string;
  readonly sequence: bigint;
  readonly daemonReason: string;
  constructor(scopeKey: string, sequence: bigint, daemonReason: string) {
    super(`client mutation sequence failed for scope ${scopeKey} at sequence ${sequence}: ${daemonReason}`);
    this.name = "ClientMutationSequenceError";
    this.scopeKey = scopeKey;
    this.sequence = sequence;
    this.daemonReason = daemonReason;
  }
}

type UnresolvedClientMutation = { sequence: bigint; logical: unknown; attempt(logical: unknown): Promise<ClientMutationAdmission>; reconcile(): Promise<void> };
type ClientMutationScope = { highWater: bigint; tail: Promise<void>; unresolved?: UnresolvedClientMutation };

export type ClientMutationSequencerOptions = { retries?: number; cooldownMs?: (attempt: number) => number };

export class ClientMutationSequencer {
  private readonly scopes = new Map<string, ClientMutationScope>();
  private readonly retries: number;
  private readonly cooldownMs: (attempt: number) => number;
  constructor(options: ClientMutationSequencerOptions = {}) {
    this.retries = Math.max(1, options.retries ?? 5);
    this.cooldownMs = options.cooldownMs ?? ((attempt) => Math.min(160, 10 * 2 ** attempt));
  }
  // run serializes mutations per scope: a later call first settles the retained
  // unresolved mutation (reconcile + immutable replay) and only then allocates
  // highWater+1 for its own logical mutation. The logical request created by
  // `create` is immutable across retries so the daemon replays the retained
  // admission instead of recording a second use of the sequence.
  async run<TLogical, TResult extends ClientMutationAdmission>(scopeKey: string, create: (sequence: bigint) => TLogical, attempt: (logical: TLogical) => Promise<TResult>, reconcile: () => Promise<void>): Promise<TResult> {
    let scope = this.scopes.get(scopeKey);
    if (!scope) { scope = { highWater: 0n, tail: Promise.resolve() }; this.scopes.set(scopeKey, scope); }
    const operation = scope.tail.then(async () => {
      if (scope!.unresolved) await this.settle(scope!, scopeKey, scope!.unresolved);
      const sequence = scope!.highWater + 1n;
      const unresolved: UnresolvedClientMutation = { sequence, logical: create(sequence), attempt: attempt as (logical: unknown) => Promise<ClientMutationAdmission>, reconcile };
      scope!.unresolved = unresolved;
      return (await this.settle(scope!, scopeKey, unresolved)) as TResult;
    });
    scope.tail = operation.then(() => undefined, () => undefined);
    return operation;
  }
  // adoptHighWater floors a scope's allocator from daemon evidence (drained
  // completion frames carry the daemon-admitted source mutation sequence). It
  // never lowers an existing high-water and is safe while an unresolved
  // mutation replays: the replay carries the same task identity, so the floor
  // can only reflect sequences the daemon already admitted for this namespace.
  // This closes the reload window where a fresh in-memory allocator would
  // otherwise restart at 1 and collide with retained daemon sequences.
  adoptHighWater(scopeKey: string, floor: bigint): void {
    if (floor <= 0n) return;
    const scope = this.scopes.get(scopeKey);
    if (!scope) { this.scopes.set(scopeKey, { highWater: floor, tail: Promise.resolve() }); return; }
    if (floor > scope.highWater) scope.highWater = floor;
  }
  // retireScopes drops every scope under a retired session token prefix (the
  // stable terminal caller at session shutdown). Scopes that are not retired
  // keep their high-water so reconnects and session re-OPENs under the same
  // terminal identity continue where they left off.
  retireScopes(sessionTokenPrefix: string): number {
    let retired = 0;
    for (const key of [...this.scopes.keys()]) if (key.startsWith(sessionTokenPrefix)) { this.scopes.delete(key); retired++; }
    return retired;
  }
  private async settle(scope: ClientMutationScope, scopeKey: string, unresolved: UnresolvedClientMutation): Promise<ClientMutationAdmission> {
    let lastError: unknown;
    for (let retry = 0; retry <= this.retries; retry++) {
      try {
        const receipt = await unresolved.attempt(unresolved.logical);
        if (scope.unresolved === unresolved) scope.unresolved = undefined;
        if (receipt.accepted) { scope.highWater = unresolved.sequence; return receipt; }
        if (isClientSequenceFailure(receipt.reason)) throw new ClientMutationSequenceError(scopeKey, unresolved.sequence, String(receipt.reason));
        // A non-sequence rejection is terminal and stores nothing daemon-side:
        // the sequence was never admitted and stays available to the next
        // mutation, matching the daemon's admission-before-retention order.
        return receipt;
      } catch (error) {
        if (error instanceof ClientMutationSequenceError) throw error;
        lastError = error;
        try { await unresolved.reconcile(); } catch (reconcileError) { lastError = reconcileError; }
        if (retry < this.retries) await new Promise<void>((resolve) => setTimeout(resolve, this.cooldownMs(retry)));
      }
    }
    throw lastError instanceof Error ? lastError : new Error("client mutation reconciliation exhausted");
  }
}
