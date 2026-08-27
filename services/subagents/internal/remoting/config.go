package remoting

import (
	"errors"

	"github.com/savioserra/lazyvim/services/subagents/internal/config"
	"github.com/tochemey/goakt/v4/remote"
)

// NewValidatedConfig validates the disabled transport boundary. GoAkt v4.5.2
// can require mTLS, but it does not expose an accepted-connection hook that can
// bind certificate identity to this service's inbound CIDR policy. Enabling
// remoting therefore fails closed and no remote.Config is constructed.
func NewValidatedConfig(cfg config.RemotingConfig, resolver config.Resolver, local config.LocalAddressSource) (*remote.Config, config.ResolvedRemoting, error) {
	resolved, err := config.ResolveRemoting(cfg, resolver, local)
	if err != nil {
		return nil, config.ResolvedRemoting{}, err
	}
	if !resolved.Enabled {
		return nil, resolved, nil
	}
	return nil, resolved, errors.New("remoting is unavailable: GoAkt v4.5.2 cannot enforce the required inbound CIDR-to-mTLS-identity binding")
}
