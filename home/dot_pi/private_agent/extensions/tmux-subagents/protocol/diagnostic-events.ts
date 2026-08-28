export type DiagnosticSeverity = "debug" | "info" | "warning" | "error";
export type DiagnosticCategory = "lifecycle" | "command" | "smoke" | "rpc" | "renderer" | "ipc" | "tmux" | "topology" | "supervisor" | "generation";
export type DiagnosticStatus = "start" | "success" | "failure" | "checkpoint" | "exit" | "restart" | "circuit-open";

interface DiagnosticBase {
  severity: DiagnosticSeverity;
  phase: string;
  status: DiagnosticStatus;
  requestId?: string;
  receiptId?: string;
  actorId?: string;
  bindingId?: string;
  error?: unknown;
  metadata?: Record<string, unknown>;
}

export type DiagnosticEvent =
  | ({ type: "DIAGNOSTIC.LIFECYCLE"; category: "lifecycle" | "generation" } & DiagnosticBase)
  | ({ type: "DIAGNOSTIC.COMMAND"; category: "command" } & DiagnosticBase)
  | ({ type: "DIAGNOSTIC.SMOKE"; category: "smoke" } & DiagnosticBase)
  | ({ type: "DIAGNOSTIC.RPC"; category: "rpc" } & DiagnosticBase)
  | ({ type: "DIAGNOSTIC.RENDERER"; category: "renderer" | "ipc" | "tmux" } & DiagnosticBase)
  | ({ type: "DIAGNOSTIC.TOPOLOGY"; category: "topology" } & DiagnosticBase)
  | ({ type: "DIAGNOSTIC.SUPERVISOR"; category: "supervisor" } & DiagnosticBase);

export type DiagnosticActorEvent =
  | (DiagnosticEvent & { acknowledge?: (error?: Error, record?: DiagnosticRecord) => void })
  | { type: "DIAGNOSTIC.QUERY"; count: number; acknowledge: (error?: Error, records?: DiagnosticRecord[]) => void }
  | { type: "DIAGNOSTIC.CRASH"; acknowledge?: (error?: Error) => void };

export interface DiagnosticRecord {
  schemaVersion: 1;
  sequence: number;
  timestamp: number;
  generation: string;
  category: DiagnosticCategory;
  severity: DiagnosticSeverity;
  phase: string;
  status: DiagnosticStatus;
  requestId?: string;
  receiptId?: string;
  actorId?: string;
  bindingId?: string;
  errorCode?: string;
  errorMessage?: string;
  metadata?: Record<string, string | number | boolean>;
}
