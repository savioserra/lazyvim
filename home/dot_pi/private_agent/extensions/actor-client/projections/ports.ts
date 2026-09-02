import type { EffectIntent } from "./types.ts";
export type ProjectionPorts = { present(intent: Extract<EffectIntent, { type: "PRESENT_COMPLETION" }>): Promise<void>; setStatus?(key: string, value?: string): void; requestRosterReplay?(epoch: bigint, sequence: bigint): void };
