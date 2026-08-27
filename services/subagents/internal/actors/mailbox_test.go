package actors_test

import (
	"errors"
	"testing"

	goakt "github.com/tochemey/goakt/v4/actor"
	goakterrors "github.com/tochemey/goakt/v4/errors"
)

func TestNonBlockingBoundedMailboxRejectsOverload(t *testing.T) {
	mailbox := goakt.NewNonBlockingBoundedMailbox(2)
	if err := mailbox.Enqueue(new(goakt.ReceiveContext)); err != nil {
		t.Fatal(err)
	}
	if err := mailbox.Enqueue(new(goakt.ReceiveContext)); err != nil {
		t.Fatal(err)
	}
	if err := mailbox.Enqueue(new(goakt.ReceiveContext)); !errors.Is(err, goakterrors.ErrMailboxFull) {
		t.Fatalf("mailbox overload was not rejected: %v", err)
	}
}
