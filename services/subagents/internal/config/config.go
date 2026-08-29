package config

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"unicode"

	"github.com/BurntSushi/toml"
	"github.com/savioserra/lazyvim/services/subagents/internal/securepath"
	"golang.org/x/sys/unix"
)

const SchemaVersion = 2

type Config struct {
	SchemaVersion int            `toml:"schema_version"`
	Service       ServiceConfig  `toml:"service"`
	HostedPi      HostedPiConfig `toml:"hosted_pi"`
	Remoting      RemotingConfig `toml:"remoting"`
}

type ServiceConfig struct {
	Enabled           bool `toml:"enabled"`
	ActorEndpointPort int  `toml:"actor_endpoint_port"`
}

type HostedPiConfig struct {
	Enabled                 bool   `toml:"enabled"`
	TmuxBinary              string `toml:"tmux_binary"`
	PiBinary                string `toml:"pi_binary"`
	BridgeExtension         string `toml:"bridge_extension"`
	TmuxServerName          string `toml:"tmux_server_name"`
	TmuxConfig              string `toml:"tmux_config"`
	StateDirectory          string `toml:"state_directory"`
	PiSessionDirectory      string `toml:"pi_session_directory"`
	CredentialDirectory     string `toml:"credential_directory"`
	AdminCredentialFile     string `toml:"admin_credential_file"`
	DefaultProjectDirectory string `toml:"default_project_directory"`
	TrustProject            bool   `toml:"trust_project"`
}

type RemotingConfig struct {
	Enabled         bool         `toml:"enabled"`
	Mode            string       `toml:"mode"`
	NetworkTrust    string       `toml:"network_trust"`
	ClusterName     string       `toml:"cluster_name"`
	NodeIdentity    string       `toml:"node_identity"`
	BindHost        string       `toml:"bind_host"`
	DNSSuffix       string       `toml:"dns_suffix"`
	Port            int          `toml:"port"`
	DiscoveryPort   int          `toml:"discovery_port"`
	PeersPort       int          `toml:"peers_port"`
	AllowedCIDRs    []string     `toml:"allowed_cidrs"`
	AddressFamilies []string     `toml:"address_families"`
	MTLSIdentity    string       `toml:"mtls_identity"`
	CAFile          string       `toml:"ca_file"`
	CertFile        string       `toml:"cert_file"`
	KeyFile         string       `toml:"key_file"`
	Peers           []PeerConfig `toml:"peers"`
}

type PeerConfig struct {
	NodeIdentity string `toml:"node_identity"`
	Host         string `toml:"host"`
	MTLSIdentity string `toml:"mtls_identity"`
	SSHTarget    string `toml:"ssh_target"`
}

type ResolvedRemoting struct {
	Enabled                   bool
	ClusterName               string
	NodeIdentity              string
	BindAddress               netip.Addr
	DNSSuffix                 string
	Port, DiscoveryPort       int
	PeersPort                 int
	MTLSIdentity              string
	CAFile, CertFile, KeyFile string
	Peers                     []ResolvedPeer
}

type ResolvedPeer struct {
	NodeIdentity string
	Host         string
	Addresses    []netip.Addr
	MTLSIdentity string
	SSHTarget    string
}

type Resolver interface {
	LookupNetIP(network, host string) ([]netip.Addr, error)
}

type LocalAddressSource interface {
	LocalAddresses() ([]netip.Addr, error)
}

type NetworkResolver struct{ resolver *net.Resolver }

func NewNetworkResolver() NetworkResolver { return NetworkResolver{resolver: net.DefaultResolver} }
func (r NetworkResolver) LookupNetIP(network, host string) ([]netip.Addr, error) {
	return r.resolver.LookupNetIP(context.Background(), network, host)
}

type InterfaceAddressSource struct{}

func (InterfaceAddressSource) LocalAddresses() ([]netip.Addr, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}
	var result []netip.Addr
	for _, item := range interfaces {
		addresses, err := item.Addrs()
		if err != nil {
			return nil, err
		}
		for _, address := range addresses {
			prefix, err := netip.ParsePrefix(address.String())
			if err == nil {
				result = append(result, prefix.Addr().Unmap())
			}
		}
	}
	return result, nil
}

func Load(path string) (Config, error) {
	clean, err := filepath.Abs(filepath.Clean(path))
	if err != nil {
		return Config{}, fmt.Errorf("resolve config path: %w", err)
	}
	if isWindowsMount(clean) {
		return Config{}, errors.New("config must use the Unix filesystem, not /mnt")
	}
	parent := filepath.Dir(clean)
	parentFile, err := securepath.OpenDir(parent, configPathValidator(os.Getuid()))
	if err != nil {
		return Config{}, fmt.Errorf("securely walk config parent: %w", err)
	}
	defer parentFile.Close()
	fd, err := unix.Openat(int(parentFile.Fd()), filepath.Base(clean), unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return Config{}, fmt.Errorf("open config without following symlinks: %w", err)
	}
	file := os.NewFile(uintptr(fd), clean)
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return Config{}, fmt.Errorf("inspect opened config: %w", err)
	}
	if !info.Mode().IsRegular() {
		return Config{}, errors.New("config must be a regular file")
	}
	if info.Mode().Perm() != 0o600 {
		return Config{}, fmt.Errorf("config mode must be exactly 0600, got %04o", info.Mode().Perm())
	}
	if info.Sys().(*syscall.Stat_t).Uid != uint32(os.Getuid()) {
		return Config{}, errors.New("config has foreign ownership")
	}
	var cfg Config
	metadata, err := toml.NewDecoder(file).Decode(&cfg)
	if err != nil {
		return Config{}, fmt.Errorf("decode config: %w", err)
	}
	if undecoded := metadata.Undecoded(); len(undecoded) != 0 {
		return Config{}, fmt.Errorf("unknown config field %q", undecoded[0].String())
	}
	if cfg.SchemaVersion != SchemaVersion {
		return Config{}, fmt.Errorf("unsupported config schema version %d", cfg.SchemaVersion)
	}
	return cfg, nil
}

func ResolveRemoting(cfg RemotingConfig, resolver Resolver, localSource LocalAddressSource) (ResolvedRemoting, error) {
	if !cfg.Enabled {
		return ResolvedRemoting{}, nil
	}
	if resolver == nil || localSource == nil {
		return ResolvedRemoting{}, errors.New("resolver and local address source are required")
	}
	if cfg.Mode != "cluster" {
		return ResolvedRemoting{}, errors.New("enabled remoting requires mode=cluster")
	}
	if strings.TrimSpace(cfg.NetworkTrust) == "" {
		return ResolvedRemoting{}, errors.New("enabled remoting requires an explicit network_trust label")
	}
	if err := logicalIdentity("cluster_name", cfg.ClusterName); err != nil {
		return ResolvedRemoting{}, err
	}
	if err := logicalIdentity("node_identity", cfg.NodeIdentity); err != nil {
		return ResolvedRemoting{}, err
	}
	if err := logicalIdentity("mtls_identity", cfg.MTLSIdentity); err != nil {
		return ResolvedRemoting{}, err
	}
	for name, value := range map[string]string{"ca_file": cfg.CAFile, "cert_file": cfg.CertFile, "key_file": cfg.KeyFile} {
		if !filepath.IsAbs(value) || value != filepath.Clean(value) {
			return ResolvedRemoting{}, fmt.Errorf("%s must be a clean absolute path", name)
		}
	}
	if err := trustedDNSHost(cfg.BindHost, cfg.DNSSuffix); err != nil {
		return ResolvedRemoting{}, fmt.Errorf("bind_host: %w", err)
	}
	ports := []int{cfg.Port, cfg.DiscoveryPort, cfg.PeersPort}
	for _, port := range ports {
		if port < 1024 || port > 65535 {
			return ResolvedRemoting{}, errors.New("remoting ports must be fixed in the range 1024..65535")
		}
	}
	if cfg.Port == cfg.DiscoveryPort || cfg.Port == cfg.PeersPort || cfg.DiscoveryPort == cfg.PeersPort {
		return ResolvedRemoting{}, errors.New("port, discovery_port, and peers_port must be distinct")
	}
	families, err := parseFamilies(cfg.AddressFamilies)
	if err != nil {
		return ResolvedRemoting{}, err
	}
	cidrs, err := parseCIDRs(cfg.AllowedCIDRs)
	if err != nil {
		return ResolvedRemoting{}, err
	}
	if len(families) != 1 || !families["ipv4"] || len(cidrs) == 0 {
		return ResolvedRemoting{}, errors.New("trusted-network remoting requires address_families=[ipv4] and at least one allowed CIDR")
	}
	local, err := localSource.LocalAddresses()
	if err != nil {
		return ResolvedRemoting{}, fmt.Errorf("enumerate local addresses: %w", err)
	}
	localSet := make(map[netip.Addr]struct{}, len(local))
	for _, address := range local {
		localSet[address.Unmap()] = struct{}{}
	}
	bindAddresses, err := resolveAllowed(cfg.BindHost, resolver, families, cidrs)
	if err != nil {
		return ResolvedRemoting{}, fmt.Errorf("resolve bind_host: %w", err)
	}
	if len(bindAddresses) != 1 {
		return ResolvedRemoting{}, fmt.Errorf("bind_host must resolve to exactly one allowed concrete IP, got %d", len(bindAddresses))
	}
	bind := bindAddresses[0]
	if bind.IsUnspecified() {
		return ResolvedRemoting{}, errors.New("bind_host must not resolve to an unspecified address")
	}
	if _, ok := localSet[bind]; !ok {
		return ResolvedRemoting{}, fmt.Errorf("bind address %s is not assigned locally", bind)
	}

	seenNodes := map[string]struct{}{cfg.NodeIdentity: {}}
	seenIdentities := map[string]struct{}{cfg.MTLSIdentity: {}}
	peers := make([]ResolvedPeer, 0, len(cfg.Peers))
	for i, peer := range cfg.Peers {
		if err := logicalIdentity("peer node_identity", peer.NodeIdentity); err != nil {
			return ResolvedRemoting{}, fmt.Errorf("peer %d: %w", i, err)
		}
		if _, exists := seenNodes[peer.NodeIdentity]; exists {
			return ResolvedRemoting{}, fmt.Errorf("peer %d: duplicate node_identity", i)
		}
		seenNodes[peer.NodeIdentity] = struct{}{}
		if err := logicalIdentity("peer mtls_identity", peer.MTLSIdentity); err != nil {
			return ResolvedRemoting{}, fmt.Errorf("peer %d: %w", i, err)
		}
		if _, exists := seenIdentities[peer.MTLSIdentity]; exists {
			return ResolvedRemoting{}, fmt.Errorf("peer %d: duplicate mtls_identity", i)
		}
		seenIdentities[peer.MTLSIdentity] = struct{}{}
		if err := trustedDNSHost(peer.Host, cfg.DNSSuffix); err != nil {
			return ResolvedRemoting{}, fmt.Errorf("peer %d: %w", i, err)
		}
		if err := sshTarget(peer.SSHTarget); err != nil {
			return ResolvedRemoting{}, fmt.Errorf("peer %d: %w", i, err)
		}
		addresses, err := resolveAllowed(peer.Host, resolver, families, cidrs)
		if err != nil {
			return ResolvedRemoting{}, fmt.Errorf("peer %d: %w", i, err)
		}
		peers = append(peers, ResolvedPeer{
			NodeIdentity: peer.NodeIdentity,
			Host:         peer.Host,
			Addresses:    addresses,
			MTLSIdentity: peer.MTLSIdentity,
			SSHTarget:    peer.SSHTarget,
		})
	}
	return ResolvedRemoting{
		Enabled:       true,
		ClusterName:   cfg.ClusterName,
		NodeIdentity:  cfg.NodeIdentity,
		BindAddress:   bind,
		DNSSuffix:     cfg.DNSSuffix,
		Port:          cfg.Port,
		DiscoveryPort: cfg.DiscoveryPort,
		PeersPort:     cfg.PeersPort,
		MTLSIdentity:  cfg.MTLSIdentity,
		CAFile:        cfg.CAFile,
		CertFile:      cfg.CertFile,
		KeyFile:       cfg.KeyFile,
		Peers:         peers,
	}, nil
}

func trustedDNSHost(host, suffix string) error {
	if suffix == "" || suffix != strings.TrimSpace(suffix) || !strings.HasPrefix(suffix, ".") || strings.HasSuffix(suffix, ".") {
		return errors.New("dns suffix must be a trim-equal suffix beginning with '.'")
	}
	if host == "" || host != strings.TrimSpace(host) || strings.HasSuffix(host, ".") || !strings.HasSuffix(host, suffix) || len(host) <= len(suffix) {
		return errors.New("host must be a full DNS name beneath the configured suffix")
	}
	return nil
}

func sshTarget(value string) error {
	if value == "" {
		return nil
	}
	if value != strings.TrimSpace(value) || len(value) > 255 || strings.HasPrefix(value, "-") {
		return errors.New("ssh_target must be bounded, trim-equal, and must not begin with '-'")
	}
	for _, character := range value {
		if unicode.IsControl(character) {
			return errors.New("ssh_target must not contain control characters")
		}
	}
	return nil
}

func configPathValidator(uid int) securepath.DirValidator {
	return func(path string, info os.FileInfo, final bool) error {
		mode := info.Mode().Perm()
		if final {
			if mode != 0o700 || info.Sys().(*syscall.Stat_t).Uid != uint32(uid) {
				return errors.New("config parent must be an owner-private 0700 directory")
			}
			return nil
		}
		owner := info.Sys().(*syscall.Stat_t).Uid
		if owner != 0 && owner != uint32(uid) {
			return fmt.Errorf("config ancestor %s is not owned by root or the current user", path)
		}
		if mode&0o022 != 0 && info.Mode()&os.ModeSticky == 0 {
			return fmt.Errorf("config ancestor %s is writable without the sticky bit (mode %04o)", path, mode)
		}
		return nil
	}
}

func isWindowsMount(path string) bool {
	clean := filepath.Clean(path)
	return clean == "/mnt" || strings.HasPrefix(clean, "/mnt/")
}

func logicalIdentity(field, value string) error {
	if value == "" || value != strings.TrimSpace(value) || len(value) > 255 || strings.ContainsAny(value, "\x00\r\n") {
		return fmt.Errorf("%s must be a non-empty bounded logical identity", field)
	}
	return nil
}

func parseFamilies(values []string) (map[string]bool, error) {
	if len(values) == 0 {
		return nil, errors.New("address_families must explicitly allow ipv4 and/or ipv6")
	}
	result := make(map[string]bool, 2)
	for _, value := range values {
		if value != "ipv4" && value != "ipv6" {
			return nil, fmt.Errorf("unsupported address family %q", value)
		}
		result[value] = true
	}
	return result, nil
}

func parseCIDRs(values []string) ([]netip.Prefix, error) {
	if len(values) == 0 {
		return nil, errors.New("allowed_cidrs must not be empty")
	}
	result := make([]netip.Prefix, 0, len(values))
	for _, value := range values {
		prefix, err := netip.ParsePrefix(value)
		if err != nil {
			return nil, fmt.Errorf("invalid allowed CIDR %q", value)
		}
		result = append(result, prefix)
	}
	return result, nil
}

func resolveAllowed(host string, resolver Resolver, families map[string]bool, cidrs []netip.Prefix) ([]netip.Addr, error) {
	addresses, err := resolver.LookupNetIP("ip", host)
	if err != nil {
		return nil, err
	}
	seen := make(map[netip.Addr]struct{}, len(addresses))
	result := make([]netip.Addr, 0, len(addresses))
	for _, raw := range addresses {
		address := raw.Unmap()
		if !address.IsValid() || address.IsUnspecified() {
			return nil, fmt.Errorf("host %q resolved to a non-concrete address", host)
		}
		family := "ipv6"
		if address.Is4() {
			family = "ipv4"
		}
		if !families[family] {
			return nil, fmt.Errorf("host %q resolved to disallowed %s address %s", host, family, address)
		}
		allowed := slices.ContainsFunc(cidrs, func(prefix netip.Prefix) bool { return prefix.Contains(address) })
		if !allowed {
			return nil, fmt.Errorf("host %q resolved outside allowed CIDRs", host)
		}
		if _, exists := seen[address]; !exists {
			seen[address] = struct{}{}
			result = append(result, address)
		}
	}
	if len(result) == 0 {
		return nil, fmt.Errorf("host %q resolved to no addresses", host)
	}
	slices.SortFunc(result, netip.Addr.Compare)
	return result, nil
}
