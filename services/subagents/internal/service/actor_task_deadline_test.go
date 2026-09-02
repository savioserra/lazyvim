package service

import (
	"testing"
	"time"
)

func TestDurableActorTaskDeadlineIsIndependentFromTransportTimeout(t *testing.T) {
	now := time.Date(2026, 9, 1, 20, 0, 0, 0, time.UTC)
	deadline := durableActorTaskDeadline(now)
	if got := deadline.Sub(now); got != 6*time.Hour {
		t.Fatalf("durable actor task lifetime = %s, want 6h", got)
	}
	if actorTaskDeliveryLifetime <= requestTimeout {
		t.Fatalf("durable task lifetime %s must outlive transport timeout %s", actorTaskDeliveryLifetime, requestTimeout)
	}
}
