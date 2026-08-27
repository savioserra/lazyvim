package actors

import (
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

// ServiceGuardian is the global lifecycle root. Reusable agents never inherit
// a Pi session lifetime.
type ServiceGuardian struct {
	ready  bool
	status string
}

func (g *ServiceGuardian) PreStart(*actor.Context) error {
	g.ready = true
	g.status = "ready"
	return nil
}
func (*ServiceGuardian) PostStop(*actor.Context) error { return nil }
func (g *ServiceGuardian) Receive(ctx *actor.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *application.Health:
		ctx.Response(&application.HealthState{Live: true, Ready: g.ready, Status: g.status})
	case *application.SetHealth:
		g.ready = message.Ready
		g.status = message.Status
	default:
		ctx.Unhandled()
	}
}
