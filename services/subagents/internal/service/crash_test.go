package service

import (
	"context"
	"time"
)

// crashWithoutRuntimeCleanup models abrupt daemon loss for restart tests. It is
// deliberately test-only: production shutdown always uses Stop.
func (s *Service) crashWithoutRuntimeCleanup(ctx context.Context) error {
	s.stopping.Store(true)
	_ = s.listener.Close()
	s.connectionMu.Lock()
	for connection := range s.activeConnections {
		_ = connection.Close()
	}
	s.connectionMu.Unlock()
	done := make(chan struct{})
	go func() { s.connections.Wait(); close(done) }()
	select {
	case <-done:
	case <-ctx.Done():
		return ctx.Err()
	}
	stopCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	return s.system.Stop(stopCtx)
}
