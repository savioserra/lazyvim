package remoting

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"

	"github.com/savioserra/lazyvim/services/subagents/internal/config"
	"github.com/savioserra/lazyvim/services/subagents/internal/securepath"
	goakttls "github.com/tochemey/goakt/v4/tls"
	"golang.org/x/sys/unix"
)

const maxTLSFileSize = 1 << 20

func loadTLS(resolved config.ResolvedRemoting) (*goakttls.Info, error) {
	caPEM, err := readPrivateTLSFile(resolved.CAFile)
	if err != nil {
		return nil, fmt.Errorf("load remoting CA: %w", err)
	}
	certPEM, err := readPrivateTLSFile(resolved.CertFile)
	if err != nil {
		return nil, fmt.Errorf("load remoting certificate: %w", err)
	}
	keyPEM, err := readPrivateTLSFile(resolved.KeyFile)
	if err != nil {
		return nil, fmt.Errorf("load remoting private key: %w", err)
	}
	certificate, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, fmt.Errorf("parse remoting key pair: %w", err)
	}
	leaf, err := x509.ParseCertificate(certificate.Certificate[0])
	if err != nil {
		return nil, fmt.Errorf("parse local remoting leaf: %w", err)
	}
	if err := exactURIIdentity(leaf, map[string]struct{}{resolved.MTLSIdentity: {}}); err != nil {
		return nil, fmt.Errorf("local remoting certificate identity: %w", err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(caPEM) {
		return nil, errors.New("remoting CA contains no certificates")
	}
	// GoAkt's cluster engine also dials its own registry endpoint, so the exact
	// local identity must be accepted alongside the configured peer identities.
	allowedPeers := make(map[string]struct{}, len(resolved.Peers)+1)
	allowedPeers[resolved.MTLSIdentity] = struct{}{}
	for _, peer := range resolved.Peers {
		allowedPeers[peer.MTLSIdentity] = struct{}{}
	}
	verifyPeerIdentity := func(state tls.ConnectionState) error {
		if len(state.PeerCertificates) == 0 {
			return errors.New("peer did not present a certificate")
		}
		return exactURIIdentity(state.PeerCertificates[0], allowedPeers)
	}
	server := &tls.Config{
		MinVersion:       tls.VersionTLS13,
		Certificates:     []tls.Certificate{certificate},
		ClientCAs:        roots,
		ClientAuth:       tls.RequireAndVerifyClientCert,
		VerifyConnection: verifyPeerIdentity,
	}
	client := &tls.Config{
		MinVersion:   tls.VersionTLS13,
		Certificates: []tls.Certificate{certificate},
		RootCAs:      roots,
		ClientCAs:    roots,
		ClientAuth:   tls.RequireAndVerifyClientCert,
		// GoAkt v4.5.2 reuses ClientConfig for both sides of the memberlist
		// transport, so it must also be server-capable and require peer certs.
		InsecureSkipVerify: true, // Chain and URI identity are verified below; GoAkt dials concrete IPs. #nosec G402
		VerifyConnection: func(state tls.ConnectionState) error {
			if len(state.PeerCertificates) == 0 {
				return errors.New("peer did not present a certificate")
			}
			intermediates := x509.NewCertPool()
			for _, certificate := range state.PeerCertificates[1:] {
				intermediates.AddCert(certificate)
			}
			if _, err := state.PeerCertificates[0].Verify(x509.VerifyOptions{Roots: roots, Intermediates: intermediates, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}); err != nil {
				return fmt.Errorf("verify peer certificate chain: %w", err)
			}
			return exactURIIdentity(state.PeerCertificates[0], allowedPeers)
		},
	}
	return &goakttls.Info{ClientConfig: client, ServerConfig: server}, nil
}

func exactURIIdentity(certificate *x509.Certificate, allowed map[string]struct{}) error {
	if certificate == nil || len(certificate.URIs) != 1 {
		return errors.New("certificate must contain exactly one URI SAN")
	}
	identity := certificate.URIs[0].String()
	if _, ok := allowed[identity]; !ok {
		return errors.New("certificate URI SAN is not allowlisted")
	}
	return nil
}

func readPrivateTLSFile(path string) ([]byte, error) {
	parent, err := securepath.OpenDir(filepath.Dir(path), tlsDirectoryValidator(os.Getuid()))
	if err != nil {
		return nil, err
	}
	defer parent.Close()
	fd, err := unix.Openat(int(parent.Fd()), filepath.Base(path), unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Sys().(*syscall.Stat_t).Uid != uint32(os.Getuid()) {
		return nil, errors.New("TLS material must be an owner-owned regular file with mode 0600")
	}
	contents, err := io.ReadAll(io.LimitReader(file, maxTLSFileSize+1))
	if err != nil {
		return nil, err
	}
	if len(contents) > maxTLSFileSize {
		return nil, errors.New("TLS material exceeds the size limit")
	}
	return contents, nil
}

func tlsDirectoryValidator(uid int) securepath.DirValidator {
	return func(path string, info os.FileInfo, final bool) error {
		mode := info.Mode().Perm()
		owner := info.Sys().(*syscall.Stat_t).Uid
		if final {
			if owner != uint32(uid) || mode != 0o700 {
				return errors.New("TLS material directory must be owner-private 0700")
			}
			return nil
		}
		if owner == uint32(uid) {
			return nil
		}
		if owner != 0 {
			return fmt.Errorf("TLS path ancestor %s has foreign ownership", path)
		}
		if mode&0o022 != 0 && info.Mode()&os.ModeSticky == 0 {
			return fmt.Errorf("root-owned TLS path ancestor %s is writable without the sticky bit", path)
		}
		return nil
	}
}
