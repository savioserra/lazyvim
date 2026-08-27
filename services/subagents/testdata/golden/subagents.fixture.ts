import { create, fromBinary, toBinary } from "@bufbuild/protobuf";
import {
  ActorMessageRequestSchema,
  ActorMessageRequest_Mode,
  EnvelopeSchema,
  HealthRequestSchema,
  type Envelope,
} from "../../api/subagents/v1/subagents_pb.ts";

export function fixtureEnvelope(): Envelope {
  return create(EnvelopeSchema, {
    protocolMajor: 1,
    protocolMinor: 0,
    sessionId: "session-fixture",
    generationId: "generation-fixture",
    requestId: "request-fixture",
    deadlineUnixMillis: 1893456000000n,
    sequence: 7n,
    callerIdentity: "caller-fixture",
    agentHandle: "",
    sessionCredential: new Uint8Array(),
    agentFence: 0n,
    payload: {
      case: "healthRequest",
      value: create(HealthRequestSchema),
    },
  });
}

export function encodeFixture(): Uint8Array {
  return toBinary(EnvelopeSchema, fixtureEnvelope());
}

export function hostedFixtureEnvelope(): Envelope {
  return create(EnvelopeSchema, {
    protocolMajor: 1,
    protocolMinor: 1,
    sessionId: "bridge-session-fixture",
    generationId: "bridge-generation-fixture",
    requestId: "bridge-request-fixture",
    deadlineUnixMillis: 1893456001234n,
    sequence: 19n,
    callerIdentity: "hosted:agent-fixture",
    agentHandle: "opaque-fenced-handle",
    sessionCredential: Uint8Array.from([1, 2, 3, 4]),
    agentFence: 23n,
    payload: {
      case: "actorMessageRequest",
      value: create(ActorMessageRequestSchema, {
        mode: ActorMessageRequest_Mode.ASK,
        target: "agent-target",
        boundedPayload: new TextEncoder().encode("bounded"),
        dedupeId: "dedupe-fixture",
        hopLimit: 8,
        chainId: "chain-fixture",
        sourceMutationSequence: 73n,
      }),
    },
  });
}

export function encodeHostedFixture(): Uint8Array {
  return toBinary(EnvelopeSchema, hostedFixtureEnvelope());
}

export function decodeFixture(bytes: Uint8Array): Envelope {
  return fromBinary(EnvelopeSchema, bytes);
}
