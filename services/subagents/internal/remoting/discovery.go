package remoting

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"slices"
	"sync"

	"github.com/savioserra/lazyvim/services/subagents/internal/config"
	"github.com/tochemey/goakt/v4/discovery"
)

var _ discovery.Provider = (*TrustedDNSDiscovery)(nil)

// TrustedDNSDiscovery is a read-only bootstrap provider. Each DiscoverPeers call
// resolves the configured DNS names again so quorum-loss rejoin does not retain
// stale trusted-network addresses.
type TrustedDNSDiscovery struct {
	resolver config.Resolver
	peers    []config.ResolvedPeer
	port     int
	mu       sync.Mutex
	closed   bool
}

func NewTrustedDNSDiscovery(resolver config.Resolver, peers []config.ResolvedPeer, discoveryPort int) (*TrustedDNSDiscovery, error) {
	if resolver == nil || len(peers) == 0 || discoveryPort < 1024 || discoveryPort > 65535 {
		return nil, errors.New("trusted DNS discovery requires a resolver, peers, and a fixed unprivileged port")
	}
	return &TrustedDNSDiscovery{resolver: resolver, peers: append([]config.ResolvedPeer(nil), peers...), port: discoveryPort}, nil
}

func (*TrustedDNSDiscovery) ID() string        { return "workstation-trusted-dns" }
func (*TrustedDNSDiscovery) Initialize() error { return nil }
func (*TrustedDNSDiscovery) Register() error   { return nil }
func (*TrustedDNSDiscovery) Deregister() error { return nil }

func (d *TrustedDNSDiscovery) DiscoverPeers() ([]string, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.closed {
		return nil, errors.New("trusted DNS discovery is closed")
	}
	allowed := netip.MustParsePrefix("100.64.0.0/10")
	seen := make(map[netip.Addr]struct{})
	var addresses []netip.Addr
	for _, peer := range d.peers {
		resolved, err := d.resolver.LookupNetIP("ip4", peer.Host)
		if err != nil {
			return nil, fmt.Errorf("resolve peer %q: %w", peer.NodeIdentity, err)
		}
		if len(resolved) == 0 {
			return nil, fmt.Errorf("peer %q resolved to no addresses", peer.NodeIdentity)
		}
		for _, raw := range resolved {
			address := raw.Unmap()
			if !address.Is4() || !allowed.Contains(address) {
				return nil, fmt.Errorf("peer %q resolved outside the trusted IPv4 range", peer.NodeIdentity)
			}
			if _, exists := seen[address]; !exists {
				seen[address] = struct{}{}
				addresses = append(addresses, address)
			}
		}
	}
	slices.SortFunc(addresses, netip.Addr.Compare)
	result := make([]string, 0, len(addresses))
	for _, address := range addresses {
		result = append(result, net.JoinHostPort(address.String(), fmt.Sprint(d.port)))
	}
	return result, nil
}

func (d *TrustedDNSDiscovery) Close() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.closed = true
	return nil
}
