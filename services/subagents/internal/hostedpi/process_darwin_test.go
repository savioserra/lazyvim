//go:build darwin

package hostedpi

import (
	"context"
	"errors"
	"os"
	"testing"
)

func TestDarwinProcessInspectionHonorsCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := processStartToken(ctx, int64(os.Getpid())); !errors.Is(err, context.Canceled) {
		t.Fatalf("Darwin process inspection ignored cancellation: %v", err)
	}
}

func TestDarwinProcessInspectionReturnsStableNonemptyToken(t *testing.T) {
	first, err := processStartToken(context.Background(), int64(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	second, err := processStartToken(context.Background(), int64(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	if first == "" || first != second {
		t.Fatalf("Darwin process token is unstable: %q %q", first, second)
	}
}
