package service

import (
	"context"
	"crypto"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net/url"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/savioserra/lazyvim/services/subagents/internal/remoting"
)

func TestPlacementAuthorityNamesAreNodeScoped(t *testing.T) {
	local := placementAuthorityName("node-a")
	remote := placementAuthorityName("node-b")
	if local == remote {
		t.Fatal("different nodes must not share a placement authority actor name")
	}
	if local != placementAuthorityName("node-a") {
		t.Fatal("placement authority name must be deterministic")
	}
	if len(local) > 64 {
		t.Fatalf("placement authority name is unexpectedly long: %d", len(local))
	}
}

func TestHostedPlacementAuthorityRejectsInvalidReplayCollisionBeforeEffects(t *testing.T) {
	authority := &hostedPlacementAuthority{service: placementTrustService(t, "node-b", "spiffe://workstation/subagents/local", "spiffe://workstation/subagents/node-b"), replays: map[string]placementReplay{}, order: []string{}}
	expired := authority.place(context.Background(), signedPlacement(t, authority.service, "node-b", "op", "d", time.Now().Add(-time.Second), "a"))
	if expired.Reason != "placement operation identity is invalid or expired" {
		t.Fatalf("expired accepted: %#v", expired)
	}
	original := signedPlacement(t, authority.service, "node-b", "op", "d", time.Now().Add(time.Minute), "a")
	authority.replays["op"] = placementReplay{digest: remotePlacementDigest(original), result: application.RemoteHostedPlacementResult{Accepted: true, AgentID: "a"}}
	replay := authority.place(context.Background(), original)
	if !replay.Accepted || replay.AgentID != "a" {
		t.Fatalf("exact replay not returned: %#v", replay)
	}
	collision := signedPlacement(t, authority.service, "node-b", "op", "other", time.Now().Add(time.Minute), "a")
	got := authority.place(context.Background(), collision)
	if got.Reason != "placement operation collision" {
		t.Fatalf("collision not rejected: %#v", got)
	}
}

func TestPlacementSignatureRejectsWrongTargetMutationAndUnallowlistedSAN(t *testing.T) {
	service := placementTrustService(t, "node-b", "spiffe://workstation/subagents/local", "spiffe://workstation/subagents/node-b")
	authority := &hostedPlacementAuthority{service: service}
	valid := signedPlacement(t, service, "node-b", "op", "d", time.Now().Add(time.Minute), "a")
	if err := authority.verifyPlacement(valid); err != nil {
		t.Fatalf("valid placement rejected: %v", err)
	}
	wrongTarget := *valid
	wrongTarget.TargetNode = "other"
	if err := authority.verifyPlacement(&wrongTarget); err == nil {
		t.Fatal("wrong target accepted")
	}
	mutated := *valid
	mutated.AgentID = "b"
	if err := authority.verifyPlacement(&mutated); err == nil {
		t.Fatal("mutated envelope accepted")
	}
	bad := placementTrustService(t, "evil", "spiffe://workstation/subagents/evil")
	badMsg := signedPlacement(t, bad, "node-b", "bad", "d", time.Now().Add(time.Minute), "a")
	if err := authority.verifyPlacement(badMsg); err == nil {
		t.Fatal("wrong CA or unallowlisted SAN accepted")
	}
}

func placementTrustService(t *testing.T, node string, identities ...string) *Service {
	t.Helper()
	_, caKey, ca := placementCA(t)
	roots := x509.NewCertPool()
	roots.AddCert(ca)
	id := identities[0]
	signer, der := placementLeaf(t, ca, caKey, id)
	allowed := map[string]struct{}{}
	for _, identity := range identities {
		allowed[identity] = struct{}{}
	}
	return &Service{actorPlane: &remoting.Runtime{NodeIdentity: node, Trust: &remoting.PlacementTrust{Signer: signer, CertificateDER: [][]byte{der}, Roots: roots, AllowedURIs: allowed}}}
}

func signedPlacement(t *testing.T, service *Service, target, op, dedupe string, deadline time.Time, agent string) *application.RemoteHostedPlacement {
	t.Helper()
	msg, err := service.signRemotePlacement(context.Background(), application.PublicNode{Identity: target}, op, deadline.UnixMilli(), agent, "/tmp/project", "QA", "qa", true)
	if err != nil {
		t.Fatal(err)
	}
	if dedupe != op {
		msg.DedupeID = dedupe
		canonical := canonicalPlacement(msg)
		sig, err := service.actorPlane.Trust.Signer.Sign(rand.Reader, canonical, crypto.Hash(0))
		if err != nil {
			t.Fatal(err)
		}
		msg.Signature = sig
	}
	return msg
}

func placementCA(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey, *x509.Certificate) {
	t.Helper()
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "ca"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, pub, priv)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return pub, priv, cert
}

func placementLeaf(t *testing.T, ca *x509.Certificate, caKey ed25519.PrivateKey, identity string) (ed25519.PrivateKey, []byte) {
	t.Helper()
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	uri, _ := url.Parse(identity)
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: "leaf"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), URIs: []*url.URL{uri}, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca, pub, caKey)
	if err != nil {
		t.Fatal(err)
	}
	return priv, der
}
