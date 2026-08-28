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

var _ discovery.Provider = (*MagicDNSDiscovery)(nil)

// MagicDNSDiscovery is a read-only bootstrap provider. Each DiscoverPeers call
// resolves the configured MagicDNS names again so quorum-loss rejoin does not
// retain stale Tailscale addresses.
type MagicDNSDiscovery struct {
	resolver config.Resolver
	peers    []config.ResolvedPeer
	port     int
	mu       sync.Mutex
	closed   bool
}

func NewMagicDNSDiscovery(resolver config.Resolver, peers []config.ResolvedPeer, discoveryPort int) (*MagicDNSDiscovery, error) {
	if resolver == nil || len(peers) == 0 || discoveryPort < 1024 || discoveryPort > 65535 {
		return nil, errors.New("MagicDNS discovery requires a resolver, peers, and a fixed unprivileged port")
	}
	return &MagicDNSDiscovery{resolver: resolver, peers: append([]config.ResolvedPeer(nil), peers...), port: discoveryPort}, nil
}

func (*MagicDNSDiscovery) ID() string        { return "workstation-tailscale-magicdns" }
func (*MagicDNSDiscovery) Initialize() error { return nil }
func (*MagicDNSDiscovery) Register() error   { return nil }
func (*MagicDNSDiscovery) Deregister() error { return nil }

func (d *MagicDNSDiscovery) DiscoverPeers() ([]string, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.closed {
		return nil, errors.New("MagicDNS discovery is closed")
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
				return nil, fmt.Errorf("peer %q resolved outside the Tailscale IPv4 range", peer.NodeIdentity)
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

func (d *MagicDNSDiscovery) Close() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.closed = true
	return nil
}
