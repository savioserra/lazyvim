package service

import (
	"bytes"
	"context"
	"crypto"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/binary"
	"errors"
	"fmt"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

const placementProtocolVersion uint32 = 1

func (s *Service) signRemotePlacement(ctx context.Context, node application.PublicNode, requestID string, deadline int64, commandAgent, project, display, role string, trust bool) (*application.RemoteHostedPlacement, error) {
	if s.actorPlane == nil || s.actorPlane.Trust == nil || s.actorPlane.Trust.Signer == nil {
		return nil, errors.New("placement signing is unavailable")
	}
	msg := &application.RemoteHostedPlacement{ProtocolVersion: placementProtocolVersion, OperationID: requestID, DedupeID: requestID, SourceNode: s.actorPlane.NodeIdentity, TargetNode: node.Identity, DeadlineUnixMillis: deadline, AgentID: commandAgent, ProjectDirectory: project, DisplayName: display, Role: role, TrustProject: trust, CertificateDER: cloneDER(s.actorPlane.Trust.CertificateDER)}
	canonical := canonicalPlacement(msg)
	digest := sha256.Sum256(canonical)
	var sig []byte
	var err error
	if _, ok := s.actorPlane.Trust.Signer.Public().(ed25519.PublicKey); ok {
		sig, err = s.actorPlane.Trust.Signer.Sign(rand.Reader, canonical, crypto.Hash(0))
	} else {
		sig, err = s.actorPlane.Trust.Signer.Sign(rand.Reader, digest[:], crypto.SHA256)
	}
	if err != nil {
		return nil, err
	}
	msg.Signature = sig
	return msg, nil
}

func (a *hostedPlacementAuthority) verifyPlacement(message *application.RemoteHostedPlacement) error {
	if message == nil || message.ProtocolVersion != placementProtocolVersion || message.OperationID == "" || message.DedupeID == "" || message.DeadlineUnixMillis <= 0 || time.Now().After(time.UnixMilli(message.DeadlineUnixMillis)) {
		return errors.New("placement operation identity is invalid or expired")
	}
	if a.service == nil || a.service.actorPlane == nil || a.service.actorPlane.Trust == nil {
		return errors.New("placement trust is unavailable")
	}
	if message.TargetNode != a.service.actorPlane.NodeIdentity {
		return errors.New("placement target node rejected")
	}
	if len(message.CertificateDER) == 0 || len(message.Signature) == 0 {
		return errors.New("placement signature is required")
	}
	leaf, err := x509.ParseCertificate(message.CertificateDER[0])
	if err != nil {
		return errors.New("placement certificate is invalid")
	}
	intermediates := x509.NewCertPool()
	for _, der := range message.CertificateDER[1:] {
		cert, err := x509.ParseCertificate(der)
		if err != nil {
			return errors.New("placement certificate chain is invalid")
		}
		intermediates.AddCert(cert)
	}
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: a.service.actorPlane.Trust.Roots, Intermediates: intermediates, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}); err != nil {
		return fmt.Errorf("placement certificate chain rejected: %w", err)
	}
	if len(leaf.URIs) != 1 {
		return errors.New("placement certificate URI SAN is invalid")
	}
	identity := leaf.URIs[0].String()
	if _, ok := a.service.actorPlane.Trust.AllowedURIs[identity]; !ok {
		return errors.New("placement certificate URI SAN is not allowlisted")
	}
	if message.SourceNode == "" {
		return errors.New("placement source node is required")
	}
	canonical := canonicalPlacement(message)
	digest := sha256.Sum256(canonical)
	if pub, ok := leaf.PublicKey.(ed25519.PublicKey); ok {
		if !ed25519.Verify(pub, canonical, message.Signature) {
			return errors.New("placement signature rejected")
		}
		return nil
	}
	if err := leaf.CheckSignature(x509.SHA256WithRSA, digest[:], message.Signature); err == nil {
		return nil
	}
	if err := leaf.CheckSignature(x509.ECDSAWithSHA256, digest[:], message.Signature); err == nil {
		return nil
	}
	return errors.New("placement signature rejected")
}

func canonicalPlacement(m *application.RemoteHostedPlacement) []byte {
	buf := new(bytes.Buffer)
	writeU32(buf, m.ProtocolVersion)
	writeString(buf, m.OperationID)
	writeString(buf, m.DedupeID)
	writeString(buf, m.SourceNode)
	writeString(buf, m.TargetNode)
	writeI64(buf, m.DeadlineUnixMillis)
	writeString(buf, m.AgentID)
	writeString(buf, m.ProjectDirectory)
	writeString(buf, m.DisplayName)
	writeString(buf, m.Role)
	if m.TrustProject {
		buf.WriteByte(1)
	} else {
		buf.WriteByte(0)
	}
	return buf.Bytes()
}
func writeString(buf *bytes.Buffer, s string) { writeU32(buf, uint32(len(s))); buf.WriteString(s) }
func writeU32(buf *bytes.Buffer, v uint32)    { _ = binary.Write(buf, binary.BigEndian, v) }
func writeI64(buf *bytes.Buffer, v int64)     { _ = binary.Write(buf, binary.BigEndian, v) }
func cloneDER(in [][]byte) [][]byte {
	out := make([][]byte, len(in))
	for i := range in {
		out[i] = append([]byte(nil), in[i]...)
	}
	return out
}
