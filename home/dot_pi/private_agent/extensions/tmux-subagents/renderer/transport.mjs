import net from "node:net";
const MAX_FRAME = 64 * 1024;

export class RendererTransport {
  constructor(ticket, handlers) { this.ticket = ticket; this.handlers = handlers; this.inputSequence = 0; this.outputSequence = 0; this.buffer = ""; this.reconnectNonce = undefined; this.reconnectAttempts = 0; this.closing = false; }
  connect() {
    this.inputSequence = 0; this.outputSequence = 0; this.buffer = "";
    this.socket = net.createConnection(this.ticket.rendererSocketPath); this.socket.setEncoding("utf8"); this.socket.setTimeout(35_000);
    this.socket.on("connect", () => {
      const reconnect = this.reconnectNonce !== undefined;
      this.write({ type: "authenticate", ticketId: this.ticket.ticketId, generation: this.ticket.generation, nonce: this.reconnectNonce ?? this.ticket.nonce, ...(reconnect ? { reconnect: true } : {}) });
    });
    this.socket.on("data", (chunk) => { try { this.receive(chunk); } catch (error) { this.handlers.error?.(error); this.socket.destroy(); } });
    this.socket.on("timeout", () => this.socket.destroy(new Error("renderer IPC timed out")));
    this.socket.on("error", (error) => this.handlers.error?.(error));
    this.socket.on("close", () => {
      if (this.closing) { this.handlers.close?.(); return; }
      if (this.reconnectAttempts >= 5) { this.handlers.close?.(); return; }
      const delay = Math.min(2000, 100 * 2 ** this.reconnectAttempts++); this.handlers.reconnecting?.(delay);
      setTimeout(() => this.connect(), delay).unref?.();
    });
  }
  receive(chunk) {
    this.buffer += chunk; if (Buffer.byteLength(this.buffer) > MAX_FRAME) throw new Error("renderer IPC frame exceeds byte limit");
    while (this.buffer.includes("\n")) {
      const split = this.buffer.indexOf("\n"); const line = this.buffer.slice(0, split); this.buffer = this.buffer.slice(split + 1); if (!line) continue;
      const frame = JSON.parse(line);
      if (frame.version !== 1 || !Number.isSafeInteger(frame.sequence) || frame.sequence <= this.outputSequence) throw new Error("renderer IPC replay or schema violation");
      this.outputSequence = frame.sequence;
      if (frame.type === "authenticated") {
        if (typeof frame.reconnectNonce !== "string" || frame.reconnectNonce.length < 32) throw new Error("renderer IPC reconnect credential is invalid");
        this.reconnectNonce = frame.reconnectNonce; this.reconnectAttempts = 0;
      }
      this.handlers.frame?.(frame);
    }
  }
  write(payload) {
    if (!this.socket || this.socket.destroyed) throw new Error("renderer IPC is disconnected");
    const frame = `${JSON.stringify({ version: 1, sequence: ++this.inputSequence, ...payload })}\n`;
    if (Buffer.byteLength(frame) > MAX_FRAME) throw new Error("renderer input exceeds byte limit"); this.socket.write(frame);
  }
  intent(intent) { this.write({ type: "intent", intent }); }
  close() { this.closing = true; this.socket?.end(); }
}
