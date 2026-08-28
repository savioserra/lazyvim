package remoting

import (
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/remote"
)

// PublicAgentSerializers returns the deterministic, explicitly registered set
// of non-protobuf actor-plane messages that may cross nodes. Keep this list
// append-only unless a wire type is intentionally retired in an ADR.
func PublicAgentSerializers() []remote.Option {
	cbor := remote.NewCBORSerializer()
	return []remote.Option{
		remote.WithSerializers(new(application.PublicAgentTell), cbor),
		remote.WithSerializers(new(application.PublicAgentAsk), cbor),
		remote.WithSerializers(new(application.PublicAgentReply), cbor),
	}
}
