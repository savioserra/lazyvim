package remoting

import (
	"crypto"
	"crypto/x509"
	"errors"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/savioserra/lazyvim/services/subagents/internal/config"
	"github.com/tochemey/goakt/v4/actor"
	"github.com/tochemey/goakt/v4/remote"
)

// Runtime is the validated GoAkt actor-plane configuration. The application
// UDS plane remains independent and is never exposed through this bundle.
type Runtime struct {
	NodeIdentity string
	MTLSIdentity string
	Remote       *remote.Config
	Cluster      *actor.ClusterConfig
	PublicNodes  map[string]application.PublicNode
	Trust        *PlacementTrust
}

type PlacementTrust struct {
	Signer         crypto.Signer
	CertificateDER [][]byte
	Roots          *x509.CertPool
	AllowedURIs    map[string]struct{}
}

// NewValidatedConfig constructs a Tailscale-bound, mutually authenticated
// three-node cluster. Tailscale ACL/device identity is the network boundary;
// URI-SAN mTLS independently limits the actor plane to explicitly trusted peers.
func NewValidatedConfig(cfg config.RemotingConfig, resolver config.Resolver, local config.LocalAddressSource) (*Runtime, config.ResolvedRemoting, error) {
	resolved, err := config.ResolveRemoting(cfg, resolver, local)
	if err != nil {
		return nil, config.ResolvedRemoting{}, err
	}
	if !resolved.Enabled {
		return nil, resolved, nil
	}
	if len(resolved.Peers) != 2 {
		return nil, resolved, errors.New("tailscale cluster mode requires exactly two peers (three nodes total)")
	}
	tlsInfo, err := loadTLS(resolved)
	if err != nil {
		return nil, resolved, err
	}
	trust, err := loadPlacementTrust(resolved)
	if err != nil {
		return nil, resolved, err
	}
	provider, err := NewMagicDNSDiscovery(resolver, resolved.Peers, resolved.DiscoveryPort)
	if err != nil {
		return nil, resolved, err
	}
	remoteOptions := []remote.Option{remote.WithTLS(tlsInfo)}
	remoteOptions = append(remoteOptions, PublicAgentSerializers()...)
	remoteConfig := remote.NewConfig(resolved.BindAddress.String(), resolved.Port, remoteOptions...)
	if err := remoteConfig.Validate(); err != nil {
		_ = provider.Close()
		return nil, resolved, err
	}
	clusterConfig := actor.NewClusterConfig().
		WithDiscovery(provider).
		WithDiscoveryPort(resolved.DiscoveryPort).
		WithPeersPort(resolved.PeersPort).
		// One discovered peer is enough to bootstrap; write quorum two prevents
		// either isolated node from accepting cluster-registry mutations.
		WithMinimumPeersQuorum(1).
		WithReplicaCount(2).
		WithWriteQuorum(2).
		WithReadQuorum(1).
		WithWriteTimeout(5 * time.Second).
		WithReadTimeout(5 * time.Second).
		WithBootstrapTimeout(30 * time.Second)
	nodes := make(map[string]application.PublicNode, len(resolved.Peers)+1)
	nodes[resolved.NodeIdentity] = application.PublicNode{Identity: resolved.NodeIdentity, Host: resolved.BindAddress.String(), Port: resolved.Port}
	for _, peer := range resolved.Peers {
		host := peer.Host
		if len(peer.Addresses) > 0 {
			host = peer.Addresses[0].String()
		}
		nodes[peer.NodeIdentity] = application.PublicNode{Identity: peer.NodeIdentity, Host: host, Port: resolved.Port}
	}
	return &Runtime{NodeIdentity: resolved.NodeIdentity, MTLSIdentity: resolved.MTLSIdentity, Remote: remoteConfig, Cluster: clusterConfig, PublicNodes: nodes, Trust: trust}, resolved, nil
}
