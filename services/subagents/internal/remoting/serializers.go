package remoting

import (
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/remote"
)

// PublicAgentSerializers returns the deterministic, explicitly registered set
// of non-protobuf actor-plane messages that may cross nodes. Keep append-only.
func PublicAgentSerializers() []remote.Option {
	cbor := remote.NewCBORSerializer()
	return []remote.Option{
		remote.WithSerializers(new(application.RemoteHostedPlacement), cbor),
		remote.WithSerializers(new(application.RemoteHostedPlacementResult), cbor),
		remote.WithSerializers(new(application.ListPublicHostedAgents), cbor),
		remote.WithSerializers(new(application.ListPublicHostedAgentsResult), cbor),
		remote.WithSerializers(new(application.PublicHostedAgent), cbor),
		remote.WithSerializers(new(application.PublicAgentSnapshotRequest), cbor),
		remote.WithSerializers(new(application.PublicAgentDirectoryEvent), cbor),
		remote.WithSerializers(new(application.RemoteAttachAgent), cbor),
		remote.WithSerializers(new(application.AttachResult), cbor),
		remote.WithSerializers(new(application.RemoteBridgeIntent), cbor),
		remote.WithSerializers(new(application.BridgeIntentResult), cbor),
		remote.WithSerializers(new(application.ActorMessageReply), cbor),
		remote.WithSerializers(new(application.AgentReference), cbor),
		remote.WithSerializers(new(application.AuthorityBinding), cbor),
		remote.WithSerializers(new(application.HostedPiRuntimeBinding), cbor),
	}
}
