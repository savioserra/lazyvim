import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { decodeFixture, encodeFixture, encodeHostedFixture, fixtureEnvelope } from "./subagents.fixture.ts";

const directory = new URL("./", import.meta.url);

function frame(payload) {
  const result = Buffer.allocUnsafe(payload.length + 4);
  result.writeUInt32BE(payload.length, 0);
  Buffer.from(payload).copy(result, 4);
  return result;
}

function verifyEveryField(decoded) {
  assert.equal(decoded.protocolMajor, 1);
  assert.equal(decoded.protocolMinor, 0);
  assert.equal(decoded.sessionId, "session-fixture");
  assert.equal(decoded.generationId, "generation-fixture");
  assert.equal(decoded.requestId, "request-fixture");
  assert.equal(decoded.deadlineUnixMillis, 1893456000000n);
  assert.equal(decoded.sequence, 7n);
  assert.equal(decoded.callerIdentity, "caller-fixture");
  assert.equal(decoded.agentHandle, "");
  assert.deepEqual(decoded.sessionCredential, new Uint8Array());
  assert.equal(decoded.agentFence, 0n);
  assert.equal(decoded.payload.case, "healthRequest");
  assert.deepEqual(decoded.payload.value, fixtureEnvelope().payload.value);
}

test("generated TypeScript descriptors deterministically match the Go frame", async () => {
  const goFrame = Buffer.from((await readFile(new URL("health-frame.hex", directory), "utf8")).trim(), "hex");
  const tsPayload = encodeFixture();
  const tsFrame = frame(tsPayload);
  assert.equal(tsFrame.readUInt32BE(0), tsPayload.length);
  assert.deepEqual(tsFrame, goFrame);
  verifyEveryField(decodeFixture(tsFrame.subarray(4)));
});

test("generated TypeScript descriptors encode every hosted bridge routing field", async () => {
  const goFrame = Buffer.from((await readFile(new URL("hosted-bridge-frame.hex", directory), "utf8")).trim(), "hex");
  const tsFrame = frame(encodeHostedFixture());
  assert.deepEqual(tsFrame, goFrame);
  const decoded = decodeFixture(goFrame.subarray(4));
  assert.equal(decoded.protocolMinor, 1);
  assert.equal(decoded.agentHandle, "opaque-fenced-handle");
  assert.equal(decoded.agentFence, 23n);
  assert.equal(decoded.payload.case, "actorMessageRequest");
  assert.equal(decoded.payload.value.mode, 2);
  assert.equal(decoded.payload.value.target, "agent-target");
  assert.equal(decoded.payload.value.chainId, "chain-fixture");
  assert.equal(new TextDecoder().decode(decoded.payload.value.boundedPayload), "bounded");
  assert.equal(decoded.payload.value.dedupeId, "dedupe-fixture");
  assert.equal(decoded.payload.value.hopLimit, 8);
  assert.equal(decoded.payload.value.sourceMutationSequence, 73n);
});

test("generated TypeScript descriptors decode every field of the Go fixture", async () => {
  const goFrame = Buffer.from((await readFile(new URL("health-frame.hex", directory), "utf8")).trim(), "hex");
  assert.equal(goFrame.readUInt32BE(0), goFrame.length - 4);
  const decoded = decodeFixture(goFrame.subarray(4));
  verifyEveryField(decoded);
  assert.deepEqual(frame(encodeFixture()), goFrame);
});
