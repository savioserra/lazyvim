package actors

import (
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

func TestRestoredAliasOutboxCanonicalizesOrQuarantines(t *testing.T) {
	canonical := repairRestoredSourceOutboxItem(application.DurableActorTaskOutboxItem{Target: application.CommunicationPeer{StableID: "project-manager", DisplayName: "PROJECT MANAGER"}, TargetRef: application.DurableActorRef{AgentID: "client:terminal-1"}, Credit: application.TaskCredit{TaskID: "task", CreditID: "stale", ExpiresAt: time.Now().Add(time.Minute)}, State: "sent"})
	if canonical.Target.StableID != "client:terminal-1" || canonical.Credit.CreditID != "" || canonical.State != "pending_credit" {
		t.Fatalf("alias outbox was not safely canonicalized: %#v", canonical)
	}
	quarantined := repairRestoredSourceOutboxItem(application.DurableActorTaskOutboxItem{Target: application.CommunicationPeer{StableID: "project-manager"}, TargetRef: application.DurableActorRef{AgentID: ""}, Credit: application.TaskCredit{TaskID: "task", CreditID: "stale", ExpiresAt: time.Now().Add(time.Minute)}, State: "sent"})
	if quarantined.Target.StableID != "project-manager" || quarantined.Credit.CreditID != "" || quarantined.State != "quarantined_alias_target" {
		t.Fatalf("ambiguous alias outbox was not quarantined fail-closed: %#v", quarantined)
	}
}
