// Client-peer mutation sequencing for the hosted Pi bridge extension.
//
// The daemon enforces one source mutation sequence namespace per hosted source
// agent across every actor-message target: a hosted bridge actorMessageRequest
// routes through SendActorTask on the hosted AgentActor, whose collision scan
// is global per source agent (an admitted sequence is retained across targets;
// reuse fails closed with "source mutation sequence collision"). Control
// intents instead remain scoped per (session, target fence) on the target.
// The allocator below therefore uses ONE monotonic message namespace per
// bridge binding across all message targets, adopts the daemon-authenticated
// high-water returned by bridge connect before allocation, allocates the next
// sequence only after the previous mutation settled, queues concurrent
// mutations, retains the immutable unresolved mutation across reconnects so the
// same logical request replays after reconcile (the daemon replays the retained
// admission by logical dedupe/chain/sequence/payload identity, while accepting
// request-id rotation after fresh process handshakes), retries transport
// failures with a bounded cooldown, and fails loud on true sequence collisions
// instead of silently burning slots.
//
// The bridge binding is process-stable (loaded once from the hosted
// environment), so reconnects keep the namespace and continue at the
// high-water; scopes retire only at session shutdown. A fresh process floors
// this allocator from the authoritative bridge handshake before the first actor
// message, closing the restart window where sequence 1 collided with retained
// daemon history for the same source agent.
//
// This module is deliberately extension-local: the regular actor-client
// extension carries an equivalent copy so no cross-extension imports appear.

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
  // adoptHighWater floors a scope's allocator from daemon bridge-handshake
  // evidence. It never lowers an existing high-water and refuses to disturb an
  // unresolved replay; callers invoke it during connect/reconnect before new
  // actor messages are allocated.
  adoptHighWater(scopeKey: string, floor: bigint): void {
    if (floor <= 0n) return;
    const scope = this.scopes.get(scopeKey);
    if (!scope) { this.scopes.set(scopeKey, { highWater: floor, tail: Promise.resolve() }); return; }
    if (floor > scope.highWater) scope.highWater = floor;
  }
  // retireScopes drops every scope under a retired bridge session token (used
  // at session shutdown after fences are detached). Scopes that are not
  // retired keep their high-water so reconnects continue where they left off.
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
        if (receipt.accepted) { if (unresolved.sequence > scope.highWater) scope.highWater = unresolved.sequence; return receipt; }
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
