package service

import (
	"context"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

func TestHostedPlacementAuthorityRejectsInvalidReplayCollisionBeforeEffects(t *testing.T) {
	authority := &hostedPlacementAuthority{replays: map[string]placementReplay{}, order: []string{}}
	expired := authority.place(context.Background(), &application.RemoteHostedPlacement{OperationID: "op", DedupeID: "d", DeadlineUnixMillis: time.Now().Add(-time.Second).UnixMilli(), AgentID: "a"})
	if expired.Reason != "placement operation identity is invalid or expired" {
		t.Fatalf("expired accepted: %#v", expired)
	}
	original := &application.RemoteHostedPlacement{OperationID: "op", DedupeID: "d", DeadlineUnixMillis: time.Now().Add(time.Minute).UnixMilli(), AgentID: "a"}
	authority.replays["op"] = placementReplay{digest: remotePlacementDigest(original), result: application.RemoteHostedPlacementResult{Accepted: true, AgentID: "a"}}
	replay := authority.place(context.Background(), original)
	if !replay.Accepted || replay.AgentID != "a" {
		t.Fatalf("exact replay not returned: %#v", replay)
	}
	collision := authority.place(context.Background(), &application.RemoteHostedPlacement{OperationID: "op", DedupeID: "other", DeadlineUnixMillis: time.Now().Add(time.Minute).UnixMilli(), AgentID: "a"})
	if collision.Reason != "placement operation collision" {
		t.Fatalf("collision not rejected: %#v", collision)
	}
}
