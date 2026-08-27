package service

import (
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

func TestClientConcurrentOpenCloseChurnDoesNotPoisonReopen(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", filepath.Join(root, "control.sock"))
	if err != nil {
		t.Fatal(err)
	}
	daemon, err := startWithListener(context.Background(), listener, HostedAdminConfig{Enabled: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge", StateDirectory: filepath.Join(root, "state"), PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), AdminCredentialFile: filepath.Join(root, "admin.json"), DefaultProjectDirectory: root}, listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	adminSession := application.OpenSession{Credential: daemon.adminCredential}
	request := func(payload *subagentsv1.Envelope_ClientSessionRequest, session application.OpenSession, requestID string) *subagentsv1.ClientSessionResponse {
		return daemon.dispatch(&subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: requestID, DeadlineUnixMillis: time.Now().Add(5 * time.Second).UnixMilli(), SessionId: session.SessionID, GenerationId: session.GenerationID, CallerIdentity: session.Caller, SessionCredential: session.Credential, Payload: payload}).GetClientSessionResponse()
	}
	open := func(requestID string) application.OpenSession {
		response := request(&subagentsv1.Envelope_ClientSessionRequest{ClientSessionRequest: &subagentsv1.ClientSessionRequest{Operation: subagentsv1.ClientSessionRequest_OPERATION_OPEN}}, adminSession, requestID)
		if response == nil || !response.Accepted {
			t.Fatalf("client open %s failed: %#v", requestID, response)
		}
		return application.OpenSession{SessionID: response.SessionId, GenerationID: response.GenerationId, Caller: response.CallerIdentity, Credential: response.SessionCredential}
	}
	closeSession := func(session application.OpenSession, requestID string) {
		response := request(&subagentsv1.Envelope_ClientSessionRequest{ClientSessionRequest: &subagentsv1.ClientSessionRequest{Operation: subagentsv1.ClientSessionRequest_OPERATION_CLOSE}}, session, requestID)
		if response == nil || !response.Accepted {
			t.Fatalf("client close %s failed: %#v", requestID, response)
		}
	}

	const total = 4096 + 128
	const workers = 16
	var wg sync.WaitGroup
	jobs := make(chan int)
	for worker := 0; worker < workers; worker++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			for index := range jobs {
				session := open(fmt.Sprintf("open-%d-%d", worker, index))
				closeSession(session, fmt.Sprintf("close-%d-%d", worker, index))
			}
		}(worker)
	}
	for index := 0; index < total; index++ {
		jobs <- index
	}
	close(jobs)
	wg.Wait()

	reopened := open("open-after-concurrent-churn")
	closeSession(reopened, "close-after-concurrent-churn")
}
