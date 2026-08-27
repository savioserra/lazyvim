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
	if host == "bind" {
		return []netip.Addr{netip.MustParseAddr("192.0.2.10")}, nil
	}
	return []netip.Addr{netip.MustParseAddr("192.0.2.11")}, nil
}

type locals struct{}

func (locals) LocalAddresses() ([]netip.Addr, error) {
	return []netip.Addr{netip.MustParseAddr("192.0.2.10")}, nil
}

func TestDisabledRemotingIsInertAndEnabledRemotingFailsClosed(t *testing.T) {
	disabled, resolved, err := remoting.NewValidatedConfig(config.RemotingConfig{}, resolver{}, locals{})
	if err != nil || disabled != nil || resolved.Enabled {
		t.Fatalf("disabled remoting was not inert: config=%#v resolved=%#v err=%v", disabled, resolved, err)
	}

	root := t.TempDir()
	enabled := config.RemotingConfig{
		Enabled:         true,
		NodeIdentity:    "node-a",
		BindHost:        "bind",
		Port:            7210,
		AllowedCIDRs:    []string{"192.0.2.0/24"},
		AddressFamilies: []string{"ipv4"},
		MTLSIdentity:    "spiffe://example/node-a",
		CAFile:          filepath.Join(root, "ca.pem"),
		CertFile:        filepath.Join(root, "node.pem"),
		KeyFile:         filepath.Join(root, "node.key"),
		Peers: []config.PeerConfig{{
			NodeIdentity: "node-b",
			Host:         "peer",
			MTLSIdentity: "spiffe://example/node-b",
		}},
	}
	remoteConfig, resolved, err := remoting.NewValidatedConfig(enabled, resolver{}, locals{})
	if err == nil || remoteConfig != nil || !resolved.Enabled || !strings.Contains(err.Error(), "inbound CIDR-to-mTLS-identity") {
		t.Fatalf("enabled remoting did not fail closed after policy resolution: config=%#v resolved=%#v err=%v", remoteConfig, resolved, err)
	}
}

func TestProductionServiceDoesNotInstallGoAktRemoting(t *testing.T) {
	contents, err := os.ReadFile(filepath.Join("..", "service", "service.go"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(contents), "actor.WithRemote(") {
		t.Fatal("production service installs GoAkt remoting without enforceable inbound identity/address policy")
	}
}
