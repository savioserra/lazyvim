package remoting_test

import (
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/savioserra/lazyvim/services/subagents/internal/config"
	"github.com/savioserra/lazyvim/services/subagents/internal/remoting"
)

type resolver struct{}

func (resolver) LookupNetIP(_, host string) ([]netip.Addr, error) {
	switch host {
	case "bind.taila.ts.net":
		return []netip.Addr{netip.MustParseAddr("100.64.0.10")}, nil
	case "peer-b.taila.ts.net":
		return []netip.Addr{netip.MustParseAddr("100.64.0.11")}, nil
	default:
		return []netip.Addr{netip.MustParseAddr("100.64.0.12")}, nil
	}
}

type locals struct{}

func (locals) LocalAddresses() ([]netip.Addr, error) {
	return []netip.Addr{netip.MustParseAddr("100.64.0.10")}, nil
}

func TestDisabledRemotingIsInertAndEnabledRemotingRequiresPrivateTLSMaterial(t *testing.T) {
	disabled, resolved, err := remoting.NewValidatedConfig(config.RemotingConfig{}, resolver{}, locals{})
	if err != nil || disabled != nil || resolved.Enabled {
		t.Fatalf("disabled remoting was not inert: config=%#v resolved=%#v err=%v", disabled, resolved, err)
	}

	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	enabled := config.RemotingConfig{
		Enabled: true, Mode: "cluster", NetworkTrust: "tailscale", ClusterName: "workstation-subagents",
		NodeIdentity: "node-a", BindHost: "bind.taila.ts.net", MagicDNSSuffix: ".taila.ts.net",
		Port: 17210, DiscoveryPort: 17211, PeersPort: 17212,
		AllowedCIDRs: []string{"100.64.0.0/10"}, AddressFamilies: []string{"ipv4"},
		MTLSIdentity: "spiffe://workstation/subagents/node-a",
		CAFile:       filepath.Join(root, "ca.pem"), CertFile: filepath.Join(root, "node.pem"), KeyFile: filepath.Join(root, "node.key"),
		Peers: []config.PeerConfig{
			{NodeIdentity: "node-b", Host: "peer-b.taila.ts.net", MTLSIdentity: "spiffe://workstation/subagents/node-b"},
			{NodeIdentity: "node-c", Host: "peer-c.taila.ts.net", MTLSIdentity: "spiffe://workstation/subagents/node-c"},
		},
	}
	runtime, resolved, err := remoting.NewValidatedConfig(enabled, resolver{}, locals{})
	if err == nil || runtime != nil || !resolved.Enabled || !strings.Contains(err.Error(), "load remoting CA") {
		t.Fatalf("enabled remoting did not require TLS material: runtime=%#v resolved=%#v err=%v", runtime, resolved, err)
	}
}

func TestProductionServiceInstallsOnlyValidatedNonRelocatingActorPlane(t *testing.T) {
	contents, err := os.ReadFile(filepath.Join("..", "service", "service.go"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(contents)
	for _, required := range []string{"actor.WithRemote(actorPlane.Remote)", "actor.WithCluster(actorPlane.Cluster)", "actor.WithoutRelocation()"} {
		if !strings.Contains(text, required) {
			t.Fatalf("production service lacks %s", required)
		}
	}
}
