package config_test

import (
	"errors"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/BurntSushi/toml"
	"github.com/savioserra/lazyvim/services/subagents/internal/config"
)

type resolver map[string][]netip.Addr

func (r resolver) LookupNetIP(_, host string) ([]netip.Addr, error) {
	addresses, ok := r[host]
	if !ok {
		return nil, errors.New("not found")
	}
	return addresses, nil
}

type locals []netip.Addr

func (l locals) LocalAddresses() ([]netip.Addr, error) { return l, nil }

func addr(value string) netip.Addr { return netip.MustParseAddr(value) }

func secureTempDir(t *testing.T) string {
	t.Helper()
	path := t.TempDir()
	if err := os.Chmod(path, 0o700); err != nil {
		t.Fatal(err)
	}
	return path
}

func validConfig() config.RemotingConfig {
	return config.RemotingConfig{
		Enabled: true, Mode: "cluster", NetworkTrust: "tailscale", ClusterName: "workstation-subagents", NodeIdentity: "node-a", BindHost: "bind.taila.ts.net", MagicDNSSuffix: ".taila.ts.net", Port: 7210, DiscoveryPort: 7211, PeersPort: 7212,
		AllowedCIDRs: []string{"100.64.0.0/10"}, AddressFamilies: []string{"ipv4"}, MTLSIdentity: "spiffe://example/node-a", CAFile: "/private/ca.pem", CertFile: "/private/node.pem", KeyFile: "/private/node.key",
		Peers: []config.PeerConfig{{NodeIdentity: "node-b", Host: "peer.taila.ts.net", MTLSIdentity: "spiffe://example/node-b", SSHTarget: "operator@relay.example --literal-one-argv"}},
	}
}

func TestResolveRemotingRequiresOneAllowedLocalBindAddress(t *testing.T) {
	cfg := validConfig()
	resolved, err := config.ResolveRemoting(cfg, resolver{
		"bind.taila.ts.net": {addr("100.64.0.4")}, "peer.taila.ts.net": {addr("100.64.0.5")},
	}, locals{addr("127.0.0.1"), addr("100.64.0.4")})
	if err != nil {
		t.Fatal(err)
	}
	if resolved.BindAddress.String() != "100.64.0.4" || resolved.Peers[0].SSHTarget != cfg.Peers[0].SSHTarget {
		t.Fatalf("unexpected resolution: %#v", resolved)
	}
}

func TestResolveRemotingFailsClosedForAmbiguousNonlocalFamilyAndPoisonedDNS(t *testing.T) {
	tests := []struct {
		name     string
		mutate   func(*config.RemotingConfig)
		resolver resolver
		locals   locals
		want     string
	}{
		{"ambiguous bind", func(*config.RemotingConfig) {}, resolver{"bind.taila.ts.net": {addr("100.64.0.4"), addr("100.64.0.6")}, "peer.taila.ts.net": {addr("100.64.0.5")}}, locals{addr("100.64.0.4"), addr("100.64.0.6")}, "exactly one"},
		{"nonlocal bind", func(*config.RemotingConfig) {}, resolver{"bind.taila.ts.net": {addr("100.64.0.4")}, "peer.taila.ts.net": {addr("100.64.0.5")}}, locals{addr("100.64.0.9")}, "not assigned locally"},
		{"poisoned peer", func(*config.RemotingConfig) {}, resolver{"bind.taila.ts.net": {addr("100.64.0.4")}, "peer.taila.ts.net": {addr("100.64.0.5"), addr("203.0.113.9")}}, locals{addr("100.64.0.4")}, "outside allowed CIDRs"},
		{"disallowed family", func(c *config.RemotingConfig) { c.AllowedCIDRs = []string{"100.64.0.0/10"} }, resolver{"bind.taila.ts.net": {addr("100.64.0.4")}, "peer.taila.ts.net": {addr("2001:db8::5")}}, locals{addr("100.64.0.4")}, "disallowed ipv6"},
		{"wildcard", func(*config.RemotingConfig) {}, resolver{"bind.taila.ts.net": {addr("0.0.0.0")}, "peer.taila.ts.net": {addr("100.64.0.5")}}, locals{addr("0.0.0.0")}, "non-concrete"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			cfg := validConfig()
			test.mutate(&cfg)
			_, err := config.ResolveRemoting(cfg, test.resolver, test.locals)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("wanted %q failure, got %v", test.want, err)
			}
		})
	}
}

func TestManagedRecognizerAcceptedCorpusLoads(t *testing.T) {
	paths, err := filepath.Glob(filepath.Join("testdata", "managed_toml_accepted", "*.toml"))
	if err != nil {
		t.Fatal(err)
	}
	if len(paths) == 0 {
		t.Fatal("managed TOML acceptance corpus is empty")
	}
	for _, source := range paths {
		t.Run(filepath.Base(source), func(t *testing.T) {
			contents, err := os.ReadFile(source)
			if err != nil {
				t.Fatal(err)
			}
			parent := filepath.Join(secureTempDir(t), "private")
			if err := os.Mkdir(parent, 0o700); err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(parent, "config.toml")
			if err := os.WriteFile(path, contents, 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := config.Load(path); err != nil {
				t.Fatalf("Lua-accepted corpus entry did not load through the production parser: %v", err)
			}
		})
	}
}

func TestBurntSushiRejectsInvalidManagedDecimalAndNamespaceSyntax(t *testing.T) {
	for _, contents := range []string{
		"schema_version = 01\n",
		"schema_version = -01\n",
		"schema_version = 9223372036854775808\n",
		"schema_version = -9223372036854775809\n",
		"schema_version\u00a0= 1\n",
		"service = 1\n[service]\nenabled = false\n",
		"[service]\nenabled = false\n[service]\nenabled = true\n",
	} {
		var decoded map[string]any
		if _, err := toml.Decode(contents, &decoded); err == nil {
			t.Fatalf("production parser accepted invalid managed syntax %q", contents)
		}
	}
}

func TestLoadUsesOwnerPrivateOpenatDescriptorPolicy(t *testing.T) {
	root := filepath.Join(secureTempDir(t), "private")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "config.toml")
	valid := []byte("schema_version = 2\n[service]\nenabled = false\n[remoting]\nenabled = false\n")
	if err := os.WriteFile(path, valid, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := config.Load(path); err == nil {
		t.Fatal("accepted widened config")
	}
	if err := os.Chmod(path, 0o400); err != nil {
		t.Fatal(err)
	}
	if _, err := config.Load(path); err == nil {
		t.Fatal("accepted 0400 instead of exact 0600")
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := config.Load(path); err != nil {
		t.Fatalf("rejected owner-private config: %v", err)
	}
	link := filepath.Join(root, "link.toml")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if _, err := config.Load(link); err == nil {
		t.Fatal("accepted final-component symlink")
	}
	parentLink := filepath.Join(secureTempDir(t), "parent-link")
	if err := os.Symlink(root, parentLink); err != nil {
		t.Fatal(err)
	}
	if _, err := config.Load(filepath.Join(parentLink, "config.toml")); err == nil {
		t.Fatal("accepted symlinked parent")
	}
	mountedLink := filepath.Join(secureTempDir(t), "mounted-link")
	if err := os.Symlink("/mnt", mountedLink); err != nil {
		t.Fatal(err)
	}
	if _, err := config.Load(filepath.Join(mountedLink, "workstation", "subagents", "config.toml")); err == nil {
		t.Fatal("accepted config path with intermediate symlink to /mnt")
	}
	if err := os.Chmod(root, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := config.Load(path); err == nil {
		t.Fatal("accepted unsafe parent directory")
	}
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(valid, []byte("unknown = true\n")...), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := config.Load(path); err == nil {
		t.Fatal("accepted unknown config field")
	}
	if _, err := config.Load("/mnt/workstation/subagents/config.toml"); err == nil || !strings.Contains(err.Error(), "/mnt") {
		t.Fatalf("did not reject WSL /mnt path: %v", err)
	}
}

func TestLoadRejectsWritableNonStickyIntermediateDirectory(t *testing.T) {
	for _, mode := range []os.FileMode{0o777, 0o770} {
		t.Run(mode.String(), func(t *testing.T) {
			unsafe := filepath.Join(secureTempDir(t), "unsafe")
			if err := os.Mkdir(unsafe, mode); err != nil {
				t.Fatal(err)
			}
			if err := os.Chmod(unsafe, mode); err != nil {
				t.Fatal(err)
			}
			parent := filepath.Join(unsafe, "private")
			if err := os.Mkdir(parent, 0o700); err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(parent, "config.toml")
			if err := os.WriteFile(path, []byte("schema_version = 2\n[service]\nenabled = false\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := config.Load(path); err == nil || !strings.Contains(err.Error(), "writable without the sticky bit") {
				t.Fatalf("accepted config beneath non-sticky %04o intermediate: %v", mode, err)
			}
		})
	}
}

func TestLoadAllowsStickyWritableIntermediateDirectory(t *testing.T) {
	sticky := filepath.Join(secureTempDir(t), "sticky")
	if err := os.Mkdir(sticky, 0o777); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(sticky, os.ModeSticky|0o777); err != nil {
		t.Fatal(err)
	}
	parent := filepath.Join(sticky, "private")
	if err := os.Mkdir(parent, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(parent, "config.toml")
	if err := os.WriteFile(path, []byte("schema_version = 2\n[service]\nenabled = false\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := config.Load(path); err != nil {
		t.Fatalf("rejected config beneath trusted sticky ancestor: %v", err)
	}
}

func TestResolveRemotingRejectsUnsafeSSHTargets(t *testing.T) {
	for _, target := range []string{" ", " operator@example", "operator@example ", "-Fconfig", "operator@example\tcommand", "operator@example\n", "operator@example\u0085", strings.Repeat("a", 256)} {
		t.Run(strings.ReplaceAll(target, " ", "space"), func(t *testing.T) {
			cfg := validConfig()
			cfg.Peers[0].SSHTarget = target
			_, err := config.ResolveRemoting(cfg, resolver{"bind.taila.ts.net": {addr("100.64.0.4")}, "peer.taila.ts.net": {addr("100.64.0.5")}}, locals{addr("100.64.0.4")})
			if err == nil || !strings.Contains(err.Error(), "ssh_target") {
				t.Fatalf("unsafe target %q accepted: %v", target, err)
			}
		})
	}
	cfg := validConfig()
	cfg.Peers[0].SSHTarget = ""
	if _, err := config.ResolveRemoting(cfg, resolver{"bind.taila.ts.net": {addr("100.64.0.4")}, "peer.taila.ts.net": {addr("100.64.0.5")}}, locals{addr("100.64.0.4")}); err != nil {
		t.Fatalf("unset ssh_target rejected: %v", err)
	}
}

func TestDisabledRemotingDoesNotResolve(t *testing.T) {
	resolved, err := config.ResolveRemoting(config.RemotingConfig{}, nil, nil)
	if err != nil || resolved.Enabled {
		t.Fatalf("disabled remoting did not remain inert: %#v %v", resolved, err)
	}
}
