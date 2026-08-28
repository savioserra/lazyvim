package remoting_test

import (
	"net/netip"
	"strings"
	"testing"

	"github.com/savioserra/lazyvim/services/subagents/internal/config"
	"github.com/savioserra/lazyvim/services/subagents/internal/remoting"
)

type changingResolver struct {
	calls int
}

func (r *changingResolver) LookupNetIP(_, _ string) ([]netip.Addr, error) {
	r.calls++
	if r.calls == 1 {
		return []netip.Addr{netip.MustParseAddr("100.64.0.21")}, nil
	}
	if r.calls == 2 {
		return []netip.Addr{netip.MustParseAddr("100.64.0.22")}, nil
	}
	return []netip.Addr{netip.MustParseAddr("100.64.0.23"), netip.MustParseAddr("203.0.113.9")}, nil
}

func TestMagicDNSDiscoveryReresolvesAndFailsClosedOnPoisonedAnswer(t *testing.T) {
	resolver := &changingResolver{}
	provider, err := remoting.NewMagicDNSDiscovery(resolver, []config.ResolvedPeer{{NodeIdentity: "peer", Host: "peer.taila.ts.net"}}, 17211)
	if err != nil {
		t.Fatal(err)
	}
	first, err := provider.DiscoverPeers()
	if err != nil || len(first) != 1 || first[0] != "100.64.0.21:17211" {
		t.Fatalf("unexpected first resolution: %v %v", first, err)
	}
	second, err := provider.DiscoverPeers()
	if err != nil || len(second) != 1 || second[0] != "100.64.0.22:17211" {
		t.Fatalf("unexpected second resolution: %v %v", second, err)
	}
	if _, err := provider.DiscoverPeers(); err == nil || !strings.Contains(err.Error(), "outside the Tailscale") {
		t.Fatalf("poisoned resolution was accepted: %v", err)
	}
	if err := provider.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := provider.DiscoverPeers(); err == nil {
		t.Fatal("closed provider accepted discovery")
	}
}
