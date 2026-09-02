package actors

import "github.com/savioserra/lazyvim/services/subagents/internal/application"

// NewBridgeDeliveryFixtureAgent keeps legacy bridge-delivery/ACK mechanics
// tests focused on seeded target deliveries. Production constructors never set
// this test-only authority; all production model work must enter as ActorTask.
func NewBridgeDeliveryFixtureAgent(registration *application.RegisterAgent) *AgentActor {
	value := NewAgentActor(registration)
	value.allowDirectModelIntentTestFixture = true
	return value
}
