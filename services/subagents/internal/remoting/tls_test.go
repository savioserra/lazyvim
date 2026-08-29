package remoting_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/config"
	"github.com/savioserra/lazyvim/services/subagents/internal/remoting"
)

type mapResolver map[string]netip.Addr

func (r mapResolver) LookupNetIP(_, host string) ([]netip.Addr, error) {
	return []netip.Addr{r[host]}, nil
}

type oneLocal netip.Addr

func (l oneLocal) LocalAddresses() ([]netip.Addr, error) { return []netip.Addr{netip.Addr(l)}, nil }

func TestValidatedRuntimeBuildsMutuallyAuthenticatedTLS(t *testing.T) {
	root := t.TempDir()
	// Owner-controlled deployment ancestors may be non-private; each material
	// directory and file remains exactly 0700/0600.
	if err := os.Chmod(root, 0o775); err != nil {
		t.Fatal(err)
	}
	caCert, caKey, caPEM := makeCA(t)
	identities := map[string]string{
		"node-a": "spiffe://workstation/subagents/node-a",
		"node-b": "spiffe://workstation/subagents/node-b",
		"node-c": "spiffe://workstation/subagents/node-c",
	}
	paths := make(map[string][3]string)
	for node, identity := range identities {
		directory := filepath.Join(root, node)
		if err := os.Mkdir(directory, 0o700); err != nil {
			t.Fatal(err)
		}
		certPEM, keyPEM := makeLeaf(t, caCert, caKey, identity)
		paths[node] = [3]string{writeTLSFile(t, directory, "ca.pem", caPEM), writeTLSFile(t, directory, "cert.pem", certPEM), writeTLSFile(t, directory, "key.pem", keyPEM)}
	}
	resolver := mapResolver{
		"peer-a.example.internal": netip.MustParseAddr("100.64.0.10"),
		"peer-b.example.internal": netip.MustParseAddr("100.64.0.11"),
		"peer-c.example.internal": netip.MustParseAddr("100.64.0.12"),
	}
	build := func(node, host string, peerNames ...string) *remoting.Runtime {
		peers := make([]config.PeerConfig, 0, len(peerNames))
		for _, peer := range peerNames {
			peers = append(peers, config.PeerConfig{NodeIdentity: "node-" + peer, Host: "peer-" + peer + ".example.internal", MTLSIdentity: identities["node-"+peer]})
		}
		material := paths[node]
		cfg := config.RemotingConfig{
			Enabled: true, Mode: "cluster", NetworkTrust: "trusted-overlay", ClusterName: "workstation-subagents", NodeIdentity: node,
			BindHost: host, DNSSuffix: ".example.internal", Port: 17210, DiscoveryPort: 17211, PeersPort: 17212,
			AllowedCIDRs: []string{"100.64.0.0/10"}, AddressFamilies: []string{"ipv4"}, MTLSIdentity: identities[node],
			CAFile: material[0], CertFile: material[1], KeyFile: material[2], Peers: peers,
		}
		runtime, _, err := remoting.NewValidatedConfig(cfg, resolver, oneLocal(resolver[host]))
		if err != nil {
			t.Fatal(err)
		}
		return runtime
	}
	a := build("node-a", "peer-a.example.internal", "b", "c")
	b := build("node-b", "peer-b.example.internal", "a", "c")
	handshakeTLS(t, a.Remote.TLS().ServerConfig, b.Remote.TLS().ClientConfig)
	// GoAkt v4.5.2 uses ClientConfig on both sides of memberlist transport and
	// dials its own registry endpoint while maintaining the routing table.
	handshakeTLS(t, a.Remote.TLS().ClientConfig, b.Remote.TLS().ClientConfig)
	handshakeTLS(t, a.Remote.TLS().ClientConfig, a.Remote.TLS().ClientConfig)
}

func handshakeTLS(t *testing.T, serverConfig, clientConfig *tls.Config) {
	t.Helper()
	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()
	server := tls.Server(serverConn, serverConfig)
	client := tls.Client(clientConn, clientConfig)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	serverResult := make(chan error, 1)
	go func() { serverResult <- server.HandshakeContext(ctx) }()
	if err := client.HandshakeContext(ctx); err != nil {
		t.Fatalf("client handshake failed: %v", err)
	}
	if err := <-serverResult; err != nil {
		t.Fatalf("server handshake failed: %v", err)
	}
}

func makeCA(t *testing.T) (*x509.Certificate, ed25519.PrivateKey, []byte) {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "test-ca"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature}
	der, err := x509.CreateCertificate(rand.Reader, template, template, public, private)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return certificate, private, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
}

func makeLeaf(t *testing.T, ca *x509.Certificate, caKey ed25519.PrivateKey, identity string) ([]byte, []byte) {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	uri, err := url.Parse(identity)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	template := &x509.Certificate{SerialNumber: big.NewInt(now.UnixNano()), Subject: pkix.Name{CommonName: identity}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), URIs: []*url.URL{uri}, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, ca, public, caKey)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(private)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
}

func writeTLSFile(t *testing.T, directory, name string, contents []byte) string {
	t.Helper()
	path := filepath.Join(directory, name)
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}
