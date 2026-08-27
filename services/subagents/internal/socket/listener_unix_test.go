//go:build linux || darwin

package socket_test

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"testing"

	workstationsocket "github.com/savioserra/lazyvim/services/subagents/internal/socket"
)

func privateTempDir(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestListenCreatesOwnerPrivateSocketAndRemovesItOnClose(t *testing.T) {
	root := filepath.Join(privateTempDir(t), "private")
	path := filepath.Join(root, "control.sock")
	listener, err := workstationsocket.Listen(path)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 || info.Sys().(*syscall.Stat_t).Uid != uint32(os.Getuid()) {
		t.Fatalf("unsafe socket metadata: mode=%04o uid=%d", info.Mode().Perm(), info.Sys().(*syscall.Stat_t).Uid)
	}
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("socket survived close: %v", err)
	}
}

func TestCloseDoesNotRemoveReplacementSocketPath(t *testing.T) {
	root := filepath.Join(privateTempDir(t), "private")
	path := filepath.Join(root, "control.sock")
	listener, err := workstationsocket.Listen(path)
	if err != nil {
		t.Fatal(err)
	}
	original := path + ".original"
	if err := os.Rename(path, original); err != nil {
		t.Fatal(err)
	}
	replacement, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	replacement.(*net.UnixListener).SetUnlinkOnClose(false)
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(path)
	if err != nil || info.Mode()&os.ModeSocket == 0 {
		t.Fatalf("replacement socket was removed: %#v %v", info, err)
	}
	_ = replacement.Close()
	_ = os.Remove(path)
	_ = os.Remove(original)
}

func TestCloseSurfacesOwnedPathCleanupFailure(t *testing.T) {
	root := filepath.Join(privateTempDir(t), "private")
	path := filepath.Join(root, "control.sock")
	listener, err := workstationsocket.Listen(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(root, 0o500); err != nil {
		t.Fatal(err)
	}
	closeErr := listener.Close()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if closeErr == nil {
		t.Fatal("socket cleanup failure was hidden")
	}
	_ = os.Remove(path)
	_ = os.Remove(path + ".owner")
}

func TestListenRejectsSymlinkAndActiveSocket(t *testing.T) {
	root := privateTempDir(t)
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(root, "target")
	if err := os.WriteFile(target, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "control.sock")
	if err := os.Symlink(target, path); err != nil {
		t.Fatal(err)
	}
	if _, err := workstationsocket.Listen(path); err == nil {
		t.Fatal("accepted socket symlink")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	active, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer active.Close()
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := workstationsocket.Listen(path); !errors.Is(err, workstationsocket.ErrSocketInUse) {
		t.Fatalf("active socket was not rejected: %v", err)
	}
}

func TestListenReapsOnlyOwnerPrivateStaleSocket(t *testing.T) {
	root := privateTempDir(t)
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "control.sock")
	stale, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	stale.(*net.UnixListener).SetUnlinkOnClose(false)
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := stale.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".owner", []byte("999999999\nmissing-process\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	listener, err := workstationsocket.Listen(path)
	if err != nil {
		t.Fatalf("owner-private stale socket was not reaped: %v", err)
	}
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestListenRejectsUnleasedStaleSocket(t *testing.T) {
	root := privateTempDir(t)
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "control.sock")
	stale, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	stale.(*net.UnixListener).SetUnlinkOnClose(false)
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := stale.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := workstationsocket.Listen(path); err == nil {
		t.Fatal("reaped stale socket without an ownership lease")
	}
}

func TestEnsurePrivateDirRejectsWidenedAndSymlinkDirectories(t *testing.T) {
	root := privateTempDir(t)
	wide := filepath.Join(root, "wide")
	if err := os.Mkdir(wide, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(wide, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := workstationsocket.EnsurePrivateDir(wide); err == nil {
		t.Fatal("accepted a predictably precreated widened directory")
	}
	link := filepath.Join(root, "link")
	if err := os.Symlink(wide, link); err != nil {
		t.Fatal(err)
	}
	if err := workstationsocket.EnsurePrivateDir(link); err == nil {
		t.Fatal("accepted symlink directory")
	}
}
