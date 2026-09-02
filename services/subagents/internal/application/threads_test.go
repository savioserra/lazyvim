package application

import (
	"crypto/sha256"
	"testing"
	"time"
)

func TestAgentThreadIdentityIsDeterministicAndCollisionFieldsAreIndependent(t *testing.T) {
	deadline := time.UnixMilli(1_800_000_000_000)
	intent := &BridgeIntent{SourceAgentID: "source", TargetAgentID: "target", RequestID: "request", DedupeID: "dedupe", ChainID: "chain", SourceMutationSequence: 7, RequiredCapability: "ask", Deadline: deadline, HopLimit: 8, Mode: BridgeMessageAsk, Payload: []byte("payload")}
	fingerprint := NewAgentThreadFingerprint("target", intent)
	threadID := fingerprint.ThreadID()
	if len(threadID) != 52 || threadID != NewAgentThreadFingerprint("target", intent).ThreadID() {
		t.Fatalf("thread identity is not stable and bounded: %q", threadID)
	}
	changedPolicy := fingerprint
	changedPolicy.HopLimit++
	if changedPolicy.ThreadID() != threadID {
		t.Fatal("collision-only policy field changed target-authoritative thread identity")
	}
	if changedPolicy.Digest() == fingerprint.Digest() {
		t.Fatal("immutable collision field was omitted from the fingerprint digest")
	}
	changedPayload := fingerprint
	changedPayload.PayloadDigest = sha256.Sum256([]byte("other"))
	if changedPayload.ThreadID() == threadID {
		t.Fatal("derivation payload digest did not change thread identity")
	}
}
