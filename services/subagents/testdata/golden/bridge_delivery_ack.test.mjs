import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { create, fromBinary, toBinary } from "@bufbuild/protobuf";
import { buildIdentityDeliveryAck } from "../../../../home/dot_pi/private_agent/extensions/hosted-pi-bridge/handlers.ts";
import { BridgeDelivery_Kind, BridgeDeliverySchema, BridgePushFrameSchema, EnvelopeSchema } from "../../../../home/dot_pi/private_agent/extensions/hosted-pi-bridge/subagents_pb.ts";

const directory = new URL("./", import.meta.url);
const identity = { runtimeId: "runtime-fixture", incarnation: 2n, piSessionId: "pi-fixture" };

// mirrorPushEnvelope reproduces the Go golden fixture (bridge-push-frame.hex)
// field-for-field with the deployed extension's generated descriptors.
function mirrorPushDelivery() {
  return create(BridgeDeliverySchema, {
    sequence: 9n,
    sourceAgentId: "hosted:agent-fixture",
    targetAgentId: "agent-target",
    requestId: "request-9",
    deadlineUnixMillis: 1893456005678n,
    dedupeId: "dedupe-9",
    hopLimit: 7,
    boundedPayload: new TextEncoder().encode("wake up"),
    kind: BridgeDelivery_Kind.PROMPT,
    chainId: "chain-9",
    sourceScope: "opaque-scope-token-9",
    completionKey: "agent-target:9:hosted:agent-fixture:request-9:dedupe-9:chain-9:1",
  });
}

function mirrorPushEnvelope(delivery) {
  return create(EnvelopeSchema, {
    protocolMajor: 1,
    protocolMinor: 1,
    sessionId: "bridge-session-fixture",
    generationId: "bridge-generation-fixture",
    requestId: "bridge-push-fixture",
    deadlineUnixMillis: 1893456001234n,
    sequence: 23n,
    callerIdentity: "hosted:agent-fixture",
    agentHandle: "opaque-fenced-handle",
    agentFence: 31n,
    payload: {
      case: "bridgePushFrame",
      value: create(BridgePushFrameSchema, {
        agentId: "agent-target",
        latestSequence: 9n,
        deliveries: [delivery ?? mirrorPushDelivery()],
      }),
    },
  });
}

function ackable(delivery) {
  return { sequence: delivery.sequence, dedupeId: delivery.dedupeId, kind: Number(delivery.kind), sourceScope: delivery.sourceScope, completionKey: delivery.completionKey };
}

test("the deployed extension decodes the Go push frame with full acknowledgement identity", async () => {
  const goFrame = Buffer.from((await readFile(new URL("bridge-push-frame.hex", directory), "utf8")).trim(), "hex");
  const decoded = fromBinary(EnvelopeSchema, goFrame.subarray(4));
  assert.equal(decoded.payload.case, "bridgePushFrame");
  const delivery = decoded.payload.value.deliveries[0];
  assert.equal(Number(delivery.sequence), 9);
  assert.equal(Number(delivery.kind), BridgeDelivery_Kind.PROMPT);
  assert.equal(delivery.sourceScope, "opaque-scope-token-9");
  assert.equal(delivery.completionKey, "agent-target:9:hosted:agent-fixture:request-9:dedupe-9:chain-9:1");
  // The extension's mirror encoding must be byte-identical to the Go frame:
  // a schema or serialization drift on fields 14/15 fails here, not in production.
  assert.equal(Buffer.from(toBinary(EnvelopeSchema, mirrorPushEnvelope())).toString("hex"), goFrame.subarray(4).toString("hex"));
});

test("buildIdentityDeliveryAck round-trips the real Go-serialized push frame", async () => {
  const goFrame = Buffer.from((await readFile(new URL("bridge-push-frame.hex", directory), "utf8")).trim(), "hex");
  const delivery = fromBinary(EnvelopeSchema, goFrame.subarray(4)).payload.value.deliveries[0];
  const ack = buildIdentityDeliveryAck("agent-target", identity, ackable(delivery), true, "", new TextEncoder().encode("WAKE-OK"));
  assert.equal(ack.agentId, "agent-target");
  assert.equal(ack.sequence, 9n);
  assert.equal(ack.dedupeId, "dedupe-9");
  assert.equal(ack.kind, "prompt");
  assert.equal(ack.sourceScope, "opaque-scope-token-9");
  assert.equal(ack.completionKey, "agent-target:9:hosted:agent-fixture:request-9:dedupe-9:chain-9:1");
  assert.equal(ack.runtimeId, "runtime-fixture");
  assert.equal(ack.piSessionId, "pi-fixture");
  const failed = buildIdentityDeliveryAck("agent-target", identity, ackable(delivery), false, "prompt run ended without an assistant answer");
  assert.equal(failed.delivered, false);
  assert.equal(failed.reason, "prompt run ended without an assistant answer");
});

test("a serialized server frame missing acknowledgement identity fails the acknowledgement loudly", () => {
  const decodeDelivery = (envelope) => fromBinary(EnvelopeSchema, toBinary(EnvelopeSchema, envelope)).payload.value.deliveries[0];
  const complete = mirrorPushDelivery();
  const stripped = {
    both: create(BridgeDeliverySchema, { sequence: 9n, dedupeId: "dedupe-9", kind: BridgeDelivery_Kind.PROMPT }),
    noScope: create(BridgeDeliverySchema, { sequence: 9n, dedupeId: "dedupe-9", kind: BridgeDelivery_Kind.PROMPT, completionKey: complete.completionKey }),
    noKey: create(BridgeDeliverySchema, { sequence: 9n, dedupeId: "dedupe-9", kind: BridgeDelivery_Kind.PROMPT, sourceScope: complete.sourceScope }),
  };
  for (const [label, delivery] of Object.entries(stripped)) {
    const decoded = decodeDelivery(mirrorPushEnvelope(delivery));
    // Proto3 zero values decode as empty strings: exactly the deployed incident
    // shape. The acknowledgement builder must throw instead of silently
    // stalling the acknowledgement chain.
    assert.equal(decoded.sourceScope === "" || decoded.completionKey === "", true, `${label} fixture unexpectedly carried identity`);
    assert.throws(() => buildIdentityDeliveryAck("agent-target", identity, ackable(decoded), true, ""), /identity is missing/, `${label} did not fail loudly`);
  }
});
