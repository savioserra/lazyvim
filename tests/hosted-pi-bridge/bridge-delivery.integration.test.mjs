import assert from "node:assert/strict";
import test from "node:test";
import { createHash, randomBytes } from "node:crypto";
import { createServer } from "node:http";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { create, fromBinary, toBinary } from "../../home/dot_pi/private_agent/extensions/hosted-pi-bridge/node_modules/@bufbuild/protobuf/dist/esm/index.js";
import { AgentOperationResponseSchema, BridgeConnectResponseSchema, BridgeDeliveryAckResponseSchema, BridgeDeliverySchema, BridgeDelivery_Kind, BridgeHeartbeatResponseSchema, BridgeLifecycleResponseSchema, BridgePollResponseSchema, BridgePushFrameSchema, EnvelopeSchema } from "../../home/dot_pi/private_agent/extensions/hosted-pi-bridge/subagents_pb.ts";

const EXTENSION_ROOT = new URL("../../home/dot_pi/private_agent/extensions/hosted-pi-bridge/", import.meta.url);
const WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// ---------------------------------------------------------------------------
// Minimal RFC 6455 server-side WebSocket codec: the extension runs against the
// real Node WebSocket client, so the mock daemon must speak the actual wire
// protocol (masked client frames, unmasked server frames, binary messages).
// ---------------------------------------------------------------------------
function parseClientFrame(buffer) {
  if (buffer.length < 2) return undefined;
  const fin = (buffer[0] & 0x80) !== 0;
  const opcode = buffer[0] & 0x0f;
  const masked = (buffer[1] & 0x80) !== 0;
  let length = buffer[1] & 0x7f;
  let offset = 2;
  if (length === 126) {
    if (buffer.length < offset + 2) return undefined;
    length = buffer.readUInt16BE(offset);
    offset += 2;
  } else if (length === 127) {
    if (buffer.length < offset + 8) return undefined;
    length = Number(buffer.readBigUInt64BE(offset));
    offset += 8;
  }
  let mask;
  if (masked) {
    if (buffer.length < offset + 4) return undefined;
    mask = buffer.subarray(offset, offset + 4);
    offset += 4;
  }
  if (buffer.length < offset + length) return undefined;
  let payload = buffer.subarray(offset, offset + length);
  if (mask) {
    const unmasked = Buffer.allocUnsafe(length);
    for (let index = 0; index < length; index += 1) unmasked[index] = payload[index] ^ mask[index & 3];
    payload = unmasked;
  }
  return { fin, opcode, payload, rest: buffer.subarray(offset + length) };
}

function encodeServerFrame(payload, opcode = 2) {
  let header;
  if (payload.length < 126) header = Buffer.from([0x80 | opcode, payload.length]);
  else if (payload.length <= 0xffff) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(payload.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(payload.length), 2);
  }
  return Buffer.concat([header, payload]);
}

function attachWebSocket(socket, onMessage, onClose) {
  socket.setNoDelay(true);
  let buffer = Buffer.alloc(0);
  let fragments;
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    for (;;) {
      const frame = parseClientFrame(buffer);
      if (!frame) return;
      buffer = frame.rest;
      if (frame.opcode === 8) { socket.end(); onClose(); return; }
      if (frame.opcode === 9) { socket.write(encodeServerFrame(frame.payload, 10)); continue; }
      if (frame.opcode === 10) continue;
      if (frame.opcode === 1 || frame.opcode === 2) {
        if (frame.fin) onMessage(frame.payload);
        else fragments = [frame.payload];
      } else if (frame.opcode === 0 && fragments) {
        fragments.push(frame.payload);
        if (frame.fin) { const whole = Buffer.concat(fragments); fragments = undefined; onMessage(whole); }
      }
    }
  });
  socket.on("close", onClose);
  socket.on("error", onClose);
}

// ---------------------------------------------------------------------------
// Mock daemon: models the live bridge surfaces the extension depends on —
// connect, heartbeat, lifecycle, ACK-gated poll cursor, and push frames. The
// acknowledgement path records every decoded bridgeDeliveryAckRequest so the
// assertions run against exactly what crossed the wire.
// ---------------------------------------------------------------------------
function startMockDaemon() {
  const daemon = { deliveries: [], acks: [], ackCursor: 0n, sockets: new Set(), pushCount: 0, currentFence: 31n, staleRejections: 0 };
  const respond = (socket, request, responseCase, schema, value) => {
    const envelope = create(EnvelopeSchema, {
      protocolMajor: 1,
      protocolMinor: 1,
      sessionId: request.sessionId,
      generationId: request.generationId,
      requestId: request.requestId,
      sequence: request.sequence,
      deadlineUnixMillis: BigInt(Date.now() + 30_000),
      payload: { case: responseCase, value: create(schema, value) },
    });
    const bytes = toBinary(EnvelopeSchema, envelope);
    const frame = Buffer.alloc(bytes.byteLength + 4);
    frame.writeUInt32BE(bytes.byteLength, 0);
    frame.set(bytes, 4);
    socket.write(encodeServerFrame(frame));
  };
  const handle = (socket, message) => {
    const request = fromBinary(EnvelopeSchema, message.subarray(4, 4 + message.readUInt32BE(0)));
    const value = request.payload.value;
    switch (request.payload.case) {
      case "bridgeConnectRequest":
        respond(socket, request, "bridgeConnectResponse", BridgeConnectResponseSchema, { accepted: true, agentHandle: "bridge-handle-integration", fence: daemon.currentFence, reason: "" });
        return;
      case "bridgeHeartbeatRequest":
        respond(socket, request, "bridgeHeartbeatResponse", BridgeHeartbeatResponseSchema, { accepted: true });
        return;
      case "bridgeLifecycleRequest":
        respond(socket, request, "bridgeLifecycleResponse", BridgeLifecycleResponseSchema, { accepted: true });
        return;
      case "bridgePollRequest": {
        const after = value.afterSequence;
        const served = daemon.deliveries.filter((delivery) => delivery.sequence > after && delivery.sequence > daemon.ackCursor);
        const latestSequence = served.length ? served[served.length - 1].sequence : (after > daemon.ackCursor ? after : daemon.ackCursor);
        respond(socket, request, "bridgePollResponse", BridgePollResponseSchema, { deliveries: served, events: [], latestSequence, more: false });
        return;
      }
      case "bridgeDeliveryAckRequest": {
        daemon.acks.push({
          agentId: value.agentId,
          sequence: value.sequence,
          dedupeId: value.dedupeId,
          delivered: value.delivered,
          reason: value.reason,
          answer: new TextDecoder().decode(value.boundedResult ?? new Uint8Array()),
          runtimeId: value.runtimeId,
          incarnation: value.incarnation,
          piSessionId: value.piSessionId,
          kind: value.kind,
          sourceScope: value.sourceScope,
          completionKey: value.completionKey,
          threadId: value.threadId,
          schedulerEpoch: value.schedulerEpoch,
          activeLease: value.activeLease,
          threadTurn: value.threadTurn,
          bridgeRunCounter: value.bridgeRunCounter,
          agentEndObserved: value.agentEndObserved,
          agentSettledObserved: value.agentSettledObserved,
        });
        if (value.dedupeId === "dedupe-rotated" && request.agentFence !== daemon.currentFence) {
          daemon.staleRejections += 1;
          respond(socket, request, "bridgeDeliveryAckResponse", BridgeDeliveryAckResponseSchema, { accepted: false, reason: "stale attachment fence", cursor: daemon.ackCursor });
          return;
        }
        if (value.sequence === daemon.ackCursor + 1n) daemon.ackCursor = value.sequence;
        const accepted = value.sequence <= daemon.ackCursor;
        respond(socket, request, "bridgeDeliveryAckResponse", BridgeDeliveryAckResponseSchema, { accepted, reason: accepted ? "" : "acknowledgement buffered behind cursor gap", cursor: daemon.ackCursor });
        return;
      }
      default:
        respond(socket, request, "agentOperationResponse", AgentOperationResponseSchema, { completed: true, revision: 1n });
    }
  };
  const server = createServer();
  server.on("upgrade", (request, socket) => {
    const key = request.headers["sec-websocket-key"];
    if (!key) { socket.destroy(); return; }
    const accept = createHash("sha1").update(`${key}${WEBSOCKET_GUID}`).digest("base64");
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    daemon.sockets.add(socket);
    attachWebSocket(socket, (message) => handle(socket, message), () => daemon.sockets.delete(socket));
  });
  daemon.server = server;
  daemon.pushDelivery = (delivery) => {
    daemon.pushCount += 1;
    const frame = create(EnvelopeSchema, {
      protocolMajor: 1,
      protocolMinor: 1,
      payload: { case: "bridgePushFrame", value: create(BridgePushFrameSchema, { agentId: "hosted-agent-int", events: [], deliveries: [delivery], latestSequence: delivery.sequence, reason: "integration push" }) },
    });
    const bytes = toBinary(EnvelopeSchema, frame);
    const message = Buffer.alloc(bytes.byteLength + 4);
    message.writeUInt32BE(bytes.byteLength, 0);
    message.set(bytes, 4);
    for (const socket of daemon.sockets) socket.write(encodeServerFrame(message));
  };
  return daemon;
}

function regularNotification(sequence, dedupeId, text) {
  return create(BridgeDeliverySchema, {
    sequence: BigInt(sequence),
    sourceAgentId: "terminal:manager",
    targetAgentId: "hosted-agent-int",
    requestId: `request-${sequence}`,
    deadlineUnixMillis: BigInt(Date.now() + 60_000),
    dedupeId,
    hopLimit: 8,
    boundedPayload: new TextEncoder().encode(text),
    kind: BridgeDelivery_Kind.NOTIFICATION,
    chainId: `chain-${sequence}`,
    source: { stableId: "manager-stable", displayName: "[redacted]", role: "" },
    target: { stableId: "hosted-agent-int", displayName: "Integration Reviewer", role: "CODE REVIEWER" },
    sourceScope: `scope-token-${sequence}`,
    completionKey: `hosted-agent-int:${sequence}:terminal:manager:request-${sequence}:${dedupeId}:chain-${sequence}:1`,
  });
}

function promptDelivery(sequence, dedupeId, promptText) {
  return create(BridgeDeliverySchema, {
    sequence: BigInt(sequence),
    sourceAgentId: "terminal:manager",
    targetAgentId: "hosted-agent-int",
    requestId: `request-${sequence}`,
    deadlineUnixMillis: BigInt(Date.now() + 60_000),
    dedupeId,
    hopLimit: 8,
    boundedPayload: new TextEncoder().encode(promptText),
    kind: BridgeDelivery_Kind.PROMPT,
    chainId: `chain-${sequence}`,
    source: { stableId: "manager-stable", displayName: "PROJECT MANAGER", role: "PROJECT MANAGER" },
    target: { stableId: "hosted-agent-int", displayName: "Integration Reviewer", role: "CODE REVIEWER" },
    sourceScope: `scope-token-${sequence}`,
    completionKey: `hosted-agent-int:${sequence}:terminal:manager:request-${sequence}:${dedupeId}:chain-${sequence}:1`,
    threadId: `thread-${sequence}`,
    schedulerEpoch: BigInt(sequence),
    activeLease: BigInt(sequence + 10),
    threadTurn: 1n,
  });
}

async function waitFor(predicate, what, timeoutMillis = 5000) {
  const deadline = Date.now() + timeoutMillis;
  for (;;) {
    if (predicate()) return;
    if (Date.now() > deadline) assert.fail(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

test("the real bridge delivery path acknowledges prompts end to end", async (t) => {
  const daemon = startMockDaemon();
  await new Promise((resolve) => daemon.server.listen(0, "127.0.0.1", resolve));
  const port = daemon.server.address().port;
  const stateDirectory = await mkdtemp(join(tmpdir(), "hosted-bridge-integration-"));
  const credentialPath = join(stateDirectory, "credential.json");
  await writeFile(credentialPath, JSON.stringify({ credential_b64: randomBytes(32).toString("base64") }), { mode: 0o600 });
  await chmod(credentialPath, 0o600);
  t.after(async () => {
    for (const socket of daemon.sockets) socket.destroy();
    await new Promise((resolve) => daemon.server.close(resolve));
    await rm(stateDirectory, { recursive: true, force: true });
  });

  const previousEnvironment = Object.fromEntries(Object.entries(process.env).filter(([key]) => key.startsWith("WS_SUBAGENTS_")));
  Object.assign(process.env, {
    WS_SUBAGENTS_ENDPOINT: `ws://127.0.0.1:${port}/actors`,
    WS_SUBAGENTS_CREDENTIAL_FILE: credentialPath,
    WS_SUBAGENTS_SESSION_ID: "bridge-session-integration",
    WS_SUBAGENTS_GENERATION_ID: "bridge-generation-integration",
    WS_SUBAGENTS_CALLER: "hosted:manager",
    WS_SUBAGENTS_AGENT_ID: "hosted-agent-int",
    WS_SUBAGENTS_RUNTIME_ID: "runtime-integration",
    WS_SUBAGENTS_INCARNATION: "3",
  });
  t.after(() => { for (const key of Object.keys(process.env)) if (key.startsWith("WS_SUBAGENTS_")) delete process.env[key]; Object.assign(process.env, previousEnvironment); });

  // The fake Pi captures exactly the surface the extension touches.
  const handlers = new Map();
  const sentUserMessages = [];
  const entries = [];
  const statuses = [];
  const fakePi = {
    registerEntryRenderer() {},
    registerCommand() {},
    registerTool() {},
    on(event, handler) { handlers.set(event, handler); },
    sendUserMessage(content, options) { sentUserMessages.push({ content, options }); },
    appendEntry(customType, data) { entries.push({ customType, data }); },
  };
  const fakeContext = () => ({ sessionManager: { getEntries: () => [], getSessionId: () => "pi-session-integration" }, ui: { setStatus: (key, value) => statuses.push({ key, value }), notify() {} } });
  const fire = async (event, payload) => { const handler = handlers.get(event); assert.ok(handler, `${event} handler was never registered`); await handler(payload, fakeContext()); };

  const extension = await import(new URL("index.ts", EXTENSION_ROOT).href);
  await extension.default(fakePi);

  // Scenario A: a queued prompt with full acknowledgement identity is served
  // by the real poll path, injected as a followUp user message, answered by a
  // simulated agent run, and acknowledged exactly once with that answer.
  daemon.deliveries.push(promptDelivery(1, "dedupe-1", "Reply exactly WAKE-INTEGRATION-OK"));
  await fire("session_start", { type: "session_start" });
  await waitFor(() => sentUserMessages.length === 1, "the queued prompt to be injected");
  assert.equal(sentUserMessages[0].options?.deliverAs, "followUp", "prompt injection must queue as followUp so a streaming agent cannot silently reject it");
  assert.match(sentUserMessages[0].content, /PROJECT MANAGER · project manager asked you/);
  assert.match(sentUserMessages[0].content, /Reply exactly WAKE-INTEGRATION-OK/);
  await fire("agent_start", { type: "agent_start" });
  await fire("agent_end", { type: "agent_end", messages: [
    { role: "user", content: [{ type: "text", text: "Reply exactly WAKE-INTEGRATION-OK" }] },
    { role: "assistant", content: [{ type: "text", text: "WAKE-INTEGRATION-OK" }] },
  ] });
  await fire("agent_settled", { type: "agent_settled" });
  await waitFor(() => daemon.acks.filter((ack) => ack.sequence === 1n).length === 1, "the successful prompt acknowledgement");
  const [happyAck] = daemon.acks.filter((ack) => ack.sequence === 1n);
  assert.equal(happyAck.agentId, "hosted-agent-int");
  assert.equal(happyAck.dedupeId, "dedupe-1");
  assert.equal(happyAck.delivered, true);
  assert.equal(happyAck.reason, "");
  assert.equal(happyAck.answer, "WAKE-INTEGRATION-OK");
  assert.equal(happyAck.runtimeId, "runtime-integration");
  assert.equal(happyAck.incarnation, 3n);
  assert.equal(happyAck.piSessionId, "pi-session-integration");
  assert.equal(happyAck.kind, "prompt");
  assert.equal(happyAck.sourceScope, "scope-token-1");
  assert.equal(happyAck.completionKey, "hosted-agent-int:1:terminal:manager:request-1:dedupe-1:chain-1:1");
  assert.deepEqual({ threadId: happyAck.threadId, schedulerEpoch: happyAck.schedulerEpoch, activeLease: happyAck.activeLease, threadTurn: happyAck.threadTurn, bridgeRunCounter: happyAck.bridgeRunCounter, agentEndObserved: happyAck.agentEndObserved, agentSettledObserved: happyAck.agentSettledObserved }, { threadId: "thread-1", schedulerEpoch: 1n, activeLease: 11n, threadTurn: 1n, bridgeRunCounter: 1n, agentEndObserved: true, agentSettledObserved: true });
  assert.equal(daemon.ackCursor, 1n, "accepted acknowledgement must advance the daemon cursor");
  const marker = entries.find((entry) => entry.customType === "hosted-pi-delivery-marker" && entry.data?.dedupeId === "dedupe-1");
  assert.ok(marker, "successful prompt acknowledgement must persist a delivery marker");
  assert.equal(marker.data.sequence, "1");
  assert.equal(marker.data.kind, 4);
  assert.deepEqual({ bridgeRunCounter: marker.data.bridgeRunCounter, agentEndObserved: marker.data.agentEndObserved, agentSettledObserved: marker.data.agentSettledObserved }, { bridgeRunCounter: "1", agentEndObserved: true, agentSettledObserved: true });

  // Scenario B: an agent run that produces no assistant answer must terminate
  // the task with exactly one failed acknowledgement so the cursor advances.
  daemon.deliveries.push(promptDelivery(2, "dedupe-2", "Reply exactly NEVER-ANSWERED"));
  await waitFor(() => sentUserMessages.length === 2, "the second prompt to be injected");
  await fire("agent_start", { type: "agent_start" });
  await fire("agent_end", { type: "agent_end", messages: [{ role: "user", content: [{ type: "text", text: "Reply exactly NEVER-ANSWERED" }] }] });
  await fire("agent_settled", { type: "agent_settled" });
  await waitFor(() => daemon.acks.filter((ack) => ack.sequence === 2n).length === 1, "the failed prompt acknowledgement");
  const [failedAck] = daemon.acks.filter((ack) => ack.sequence === 2n);
  assert.equal(failedAck.delivered, false);
  assert.match(failedAck.reason, /without an assistant answer/);
  assert.equal(failedAck.answer, "");
  assert.equal(failedAck.kind, "prompt");
  assert.equal(failedAck.sourceScope, "scope-token-2");
  assert.equal(daemon.ackCursor, 2n);
  assert.equal(daemon.acks.length, 2, "no stray acknowledgements crossed the wire");

  // Scenario C: the daemon replays an already-acknowledged prompt through the
  // push path. Re-injecting it would duplicate the model run, but silently
  // skipping it wedges the daemon cursor forever: the bridge must instead
  // re-acknowledge idempotently exactly once.
  daemon.pushDelivery(daemon.deliveries[0]);
  await waitFor(() => daemon.acks.filter((ack) => ack.sequence === 1n).length === 2, "the replayed prompt acknowledgement");
  const [replayedAck] = daemon.acks.filter((ack) => ack.sequence === 1n).slice(1);
  assert.equal(replayedAck.delivered, true);
  assert.match(replayedAck.reason, /replayed/);
  assert.deepEqual({ threadId: replayedAck.threadId, schedulerEpoch: replayedAck.schedulerEpoch, activeLease: replayedAck.activeLease, threadTurn: replayedAck.threadTurn, bridgeRunCounter: replayedAck.bridgeRunCounter, agentEndObserved: replayedAck.agentEndObserved, agentSettledObserved: replayedAck.agentSettledObserved }, { threadId: happyAck.threadId, schedulerEpoch: happyAck.schedulerEpoch, activeLease: happyAck.activeLease, threadTurn: happyAck.threadTurn, bridgeRunCounter: happyAck.bridgeRunCounter, agentEndObserved: true, agentSettledObserved: true });
  assert.equal(sentUserMessages.length, 2, "a replayed prompt must never be injected twice");
  await new Promise((resolve) => setTimeout(resolve, 120));
  assert.equal(daemon.acks.length, 3, "the replay produced exactly one additional acknowledgement");

  // Scenario D: a regular notification delivered under a stale rotated fence is
  // rejected once by the daemon, refreshed through reconnect, and acknowledged
  // exactly once with the same delivery identity. The regular delivery must not
  // be reinjected or churn duplicate cards while the credential/fence material
  // remains redacted from human-visible entries.
  daemon.currentFence = 32n;
  daemon.pushDelivery(regularNotification(3, "dedupe-rotated", "rotated [redacted] notification"));
  await waitFor(() => daemon.acks.filter((ack) => ack.dedupeId === "dedupe-rotated").length === 2, "the stale-fence rejection and refreshed acknowledgement");
  assert.equal(daemon.staleRejections, 1);
  const rotatedAcks = daemon.acks.filter((ack) => ack.dedupeId === "dedupe-rotated");
  assert.equal(rotatedAcks[0].delivered, true);
  assert.equal(rotatedAcks[1].delivered, true);
  assert.equal(rotatedAcks[0].sourceScope, rotatedAcks[1].sourceScope);
  assert.equal(rotatedAcks[0].completionKey, rotatedAcks[1].completionKey);
  assert.equal(daemon.ackCursor, 3n);
  await new Promise((resolve) => setTimeout(resolve, 120));
  assert.equal(daemon.acks.filter((ack) => ack.dedupeId === "dedupe-rotated").length, 2, "rotated ACK retry must stop after the accepted refresh");
  assert.equal(entries.filter((entry) => entry.customType === "hosted-pi-communication" && /dedupe-rotated|rotated \[redacted\] notification/.test(JSON.stringify(entry.data))).length, 1, "rotated delivery rendered one card");

  // Diagnostics: every prompt lifecycle transition and acknowledgement outcome
  // must be visible as bounded, payload-free session entries.
  const diagnosticLines = entries.filter((entry) => entry.customType === "hosted-pi-communication").map((entry) => entry.data?.line ?? "");
  assert.ok(diagnosticLines.some((line) => /prompt injected · sequence=1 · dedupeId=dedupe-1/.test(line)), `injection diagnostics missing: ${JSON.stringify(diagnosticLines)}`);
  assert.ok(diagnosticLines.some((line) => /prompt ack · agent=hosted-agent-int · sequence=1 · outcome=accepted · delivered=true/.test(line)), `acknowledgement diagnostics missing: ${JSON.stringify(diagnosticLines)}`);
  assert.ok(diagnosticLines.some((line) => /sequence=2 · outcome=accepted · delivered=false/.test(line)), `failure-branch diagnostics missing: ${JSON.stringify(diagnosticLines)}`);
  assert.ok(diagnosticLines.some((line) => /sequence=1 · outcome=accepted · replayed=true/.test(line)), `replay diagnostics missing: ${JSON.stringify(diagnosticLines)}`);
  for (const line of diagnosticLines) { assert.ok(line.length <= 200); assert.doesNotMatch(line, /[\r\n\t\x00]/); }

  // Clean shutdown closes the bridge without further wire traffic.
  await fire("session_shutdown", { type: "session_shutdown" });
  await waitFor(() => daemon.acks.length === 5 && statuses.some((status) => status.key === "hosted-pi-bridge" && status.value === undefined), "bridge shutdown");
  const bridgeStatuses = statuses.filter((status) => status.key === "hosted-pi-bridge").map((status) => status.value);
  assert.ok(bridgeStatuses.includes("hosted bridge ready"), `bridge never reported ready: ${JSON.stringify(bridgeStatuses)}`);
  for (const status of bridgeStatuses) assert.doesNotMatch(String(status), /degraded/, `the happy-path run must never degrade: ${JSON.stringify(bridgeStatuses)}`);
});
