export interface TopologyLimits { maxPanesPerWindow: number; maxWindows: number; layout: "tiled" }
export const DEFAULT_TOPOLOGY_LIMITS: TopologyLimits = { maxPanesPerWindow: 4, maxWindows: 4, layout: "tiled" };
