export interface AuthorityIdentity { runId: string; childId?: string }
export interface PaneIdentity { socketPath: string; paneId: string; panePid: number; paneTty: string; sessionId: string }
export type ControlOperation = "status" | "steer" | "interrupt" | "stop" | "resume";
export interface DeliveryStatus { ok: boolean; message: string; at?: number }
export interface SupervisorHealth { [supervisorId: string]: string }
