//go:build linux || darwin

package socket

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestStaleSocketLeaseIsolationFailureDoesNotOverwriteReplacement(t *testing.T) {
	path := staleSocketFixture(t)
	var replacement net.Listener
	staleIsolationHook = func(stage, socketPath, leasePath, _ string) {
		if stage != "socket" {
			return
		}
		var err error
		replacement, err = net.Listen("unix", socketPath)
		if err != nil {
			t.Fatal(err)
		}
		replacement.(*net.UnixListener).SetUnlinkOnClose(false)
		if err := os.Chmod(socketPath, 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Rename(leasePath, leasePath+".raced"); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() { staleIsolationHook = nil })
	if err := removeStaleWithLock(t, path); err == nil {
		t.Fatal("lease isolation race unexpectedly succeeded")
	}
	if replacement == nil {
		t.Fatal("race hook did not install replacement socket")
	}
	info, err := os.Lstat(path)
	if err != nil || info.Mode()&os.ModeSocket == 0 {
		t.Fatalf("rollback removed or replaced concurrent socket: %#v %v", info, err)
	}
	_ = replacement.Close()
}

func TestStaleSocketIdentityFailureDoesNotRollbackOverReplacements(t *testing.T) {
	path := staleSocketFixture(t)
	var replacement net.Listener
	const replacementLease = "424242424\nreplacement\n"
	staleIsolationHook = func(stage, socketPath, leasePath, isolationDirectory string) {
		if stage != "lease" {
			return
		}
		var err error
		replacement, err = net.Listen("unix", socketPath)
		if err != nil {
			t.Fatal(err)
		}
		replacement.(*net.UnixListener).SetUnlinkOnClose(false)
		if err := os.Chmod(socketPath, 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(leasePath, []byte(replacementLease), 0o600); err != nil {
			t.Fatal(err)
		}
		isolatedSocket := filepath.Join(isolationDirectory, filepath.Base(socketPath))
		if err := os.Remove(isolatedSocket); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(isolatedSocket, []byte("changed"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() { staleIsolationHook = nil })
	if err := removeStaleWithLock(t, path); err == nil {
		t.Fatal("post-isolation identity race unexpectedly succeeded")
	}
	info, err := os.Lstat(path)
	if err != nil || info.Mode()&os.ModeSocket == 0 {
		t.Fatalf("identity failure rollback removed concurrent socket: %#v %v", info, err)
	}
	contents, err := os.ReadFile(path + ".owner")
	if err != nil || string(contents) != replacementLease {
		t.Fatalf("identity failure rollback changed concurrent lease: %q %v", contents, err)
	}
	_ = replacement.Close()
}

func staleSocketFixture(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "control.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	listener.(*net.UnixListener).SetUnlinkOnClose(false)
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".owner", []byte("999999999\nmissing-process\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestPreRenameSocketReplacementIsNeverMoved(t *testing.T) {
	path := staleSocketFixture(t)
	var replacement net.Listener
	preStaleIsolationHook = func(stage, socketPath, _, _ string) {
		if stage != "socket" {
			return
		}
		if err := os.Remove(socketPath); err != nil {
			t.Fatal(err)
		}
		var err error
		replacement, err = net.Listen("unix", socketPath)
		if err != nil {
			t.Fatal(err)
		}
		replacement.(*net.UnixListener).SetUnlinkOnClose(false)
		if err := os.Chmod(socketPath, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() { preStaleIsolationHook = nil })
	if err := removeStaleWithLock(t, path); err == nil {
		t.Fatal("pre-rename socket replacement unexpectedly succeeded")
	}
	if info, err := os.Lstat(path); err != nil || info.Mode()&os.ModeSocket == 0 {
		t.Fatalf("pre-rename replacement was moved: %#v %v", info, err)
	}
	_ = replacement.Close()
}

func TestPreRenameLeaseReplacementIsNeverMoved(t *testing.T) {
	path := staleSocketFixture(t)
	const replacementLease = "424242424\nreplacement\n"
	var replacement net.Listener
	preStaleIsolationHook = func(stage, socketPath, leasePath, _ string) {
		if stage != "lease" {
			return
		}
		var err error
		replacement, err = net.Listen("unix", socketPath)
		if err != nil {
			t.Fatal(err)
		}
		replacement.(*net.UnixListener).SetUnlinkOnClose(false)
		if err := os.Chmod(socketPath, 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Rename(leasePath, leasePath+".stale"); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(leasePath, []byte(replacementLease), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() { preStaleIsolationHook = nil })
	if err := removeStaleWithLock(t, path); err == nil {
		t.Fatal("pre-rename lease replacement unexpectedly succeeded")
	}
	if contents, err := os.ReadFile(path + ".owner"); err != nil || string(contents) != replacementLease {
		t.Fatalf("pre-rename replacement lease was moved: %q %v", contents, err)
	}
	if info, err := os.Lstat(path); err != nil || info.Mode()&os.ModeSocket == 0 {
		t.Fatalf("concurrent endpoint was clobbered: %#v %v", info, err)
	}
	_ = replacement.Close()
}

func TestIndeterminateProcessIdentityFailsClosed(t *testing.T) {
	path := staleSocketFixture(t)
	processIdentityLookup = func(int, string) processIdentityState { return processIndeterminate }
	t.Cleanup(func() { processIdentityLookup = lookupProcessIdentity })
	if err := removeStaleWithLock(t, path); err == nil {
		t.Fatal("indeterminate process identity was treated as dead")
	}
	if _, err := os.Lstat(path); err != nil {
		t.Fatalf("indeterminate lookup isolated socket: %v", err)
	}
	if _, err := os.Lstat(path + ".owner"); err != nil {
		t.Fatalf("indeterminate lookup isolated lease: %v", err)
	}
}

func TestConcurrentCooperatingStartsSerializePublication(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "control.sock")
	const starts = 12
	ready := make(chan struct{})
	results := make(chan struct {
		listener *Listener
		err      error
	}, starts)
	var group sync.WaitGroup
	for range starts {
		group.Add(1)
		go func() {
			defer group.Done()
			<-ready
			listener, err := Listen(path)
			results <- struct {
				listener *Listener
				err      error
			}{listener, err}
		}()
	}
	close(ready)
	group.Wait()
	close(results)
	var winner *Listener
	for result := range results {
		if result.err == nil {
			if winner != nil {
				t.Fatal("multiple cooperating starts published the endpoint")
			}
			winner = result.listener
		} else if !errors.Is(result.err, ErrSocketInUse) {
			t.Fatalf("serialized start failed unexpectedly: %v", result.err)
		}
	}
	if winner == nil {
		t.Fatal("no cooperating start published the endpoint")
	}
	if err := winner.Close(); err != nil {
		t.Fatal(err)
	}
}

func removeStaleWithLock(t *testing.T, path string) error {
	t.Helper()
	lock, err := acquireEndpointLock(path)
	if err != nil {
		return err
	}
	defer lock.release()
	return removeProvenStaleSocket(path, lock)
}

func TestEndpointLockPathReplacementFailsPublicationClosed(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "control.sock")
	leaseVerificationHook = func(string) {
		lockPath := filepath.Join(root, ".control.sock.startup.lock")
		if err := os.Rename(lockPath, lockPath+".original"); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(lockPath, nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() { leaseVerificationHook = nil })
	if listener, err := Listen(path); err == nil {
		_ = listener.Close()
		t.Fatal("endpoint published after startup lock pathname replacement")
	}
	if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("failed publication left socket path: %v", err)
	}
	if _, err := os.Lstat(path + ".owner"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("failed publication left lease path: %v", err)
	}
}

func TestWriteLeaseFailureDoesNotRemoveReplacementIdentity(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "control.sock.owner")
	original := path + ".original"
	leaseVerificationHook = func(current string) {
		if err := os.Rename(current, original); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(current, []byte("999999999\nreplacement\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() { leaseVerificationHook = nil })
	lock, err := acquireEndpointLock(strings.TrimSuffix(path, ".owner"))
	if err != nil {
		t.Fatal(err)
	}
	defer lock.release()
	if _, err := writeLease(path, lock); err == nil {
		t.Fatal("replacement race did not fail lease verification")
	}
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("guarded failure cleanup removed replacement: %v", err)
	}
	if string(contents) != "999999999\nreplacement\n" {
		t.Fatalf("replacement changed: %q", contents)
	}
}
