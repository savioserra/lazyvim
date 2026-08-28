package service

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"time"

	"github.com/coder/websocket"
	"github.com/savioserra/lazyvim/services/subagents/internal/remoting"
)

const actorWebSocketPath = "/actors"

// StartWebSocketConfigured starts the workstation actor control plane over RFC
// WebSocket binary frames. The protobuf envelope framing is unchanged inside the
// WebSocket stream so domain dispatch, authorization, replay, and push delivery
// stay transport-neutral.
type websocketTransport struct{}

func StartWebSocketConfigured(ctx context.Context, listenAddress string, hosted HostedAdminConfig, runtime ...*remoting.Runtime) (*Service, error) {
	listener, err := net.Listen("tcp", listenAddress)
	if err != nil {
		return nil, fmt.Errorf("listen actor websocket endpoint: %w", err)
	}
	options := []any{hosted, websocketTransport{}}
	for _, item := range runtime {
		options = append(options, item)
	}
	return startWithListener(ctx, listener, options...)
}

func (s *Service) acceptWebSocketLoop() {
	defer s.connections.Done()
	server := &http.Server{ReadHeaderTimeout: 5 * time.Second}
	handler := http.NewServeMux()
	handler.HandleFunc(actorWebSocketPath, func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{CompressionMode: websocket.CompressionDisabled})
		if err != nil {
			return
		}
		stream := websocket.NetConn(r.Context(), conn, websocket.MessageBinary)
		s.acceptStreamConnection(stream)
	})
	server.Handler = handler
	go func() {
		<-s.stopContextDone()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	if err := server.Serve(s.listener); err != nil && !s.stopping.Load() && err != http.ErrServerClosed {
		s.markAdmissionFailure(fmt.Errorf("websocket admission: %w", err))
	}
}

func (s *Service) acceptStreamConnection(connection net.Conn) {
	select {
	case s.connectionSlots <- struct{}{}:
		s.connectionMu.Lock()
		if s.stopping.Load() {
			s.connectionMu.Unlock()
			<-s.connectionSlots
			_ = connection.Close()
			return
		}
		s.activeConnections[connection] = struct{}{}
		s.connections.Add(1)
		s.connectionMu.Unlock()
		go func() {
			defer s.connections.Done()
			defer func() { <-s.connectionSlots }()
			s.handleConnection(connection)
		}()
	default:
		_ = connection.Close()
	}
}

func (s *Service) stopContextDone() <-chan struct{} {
	done := make(chan struct{})
	go func() {
		for !s.stopping.Load() {
			time.Sleep(50 * time.Millisecond)
		}
		close(done)
	}()
	return done
}
