//go:build linux || darwin

package socket

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/securepath"
	"golang.org/x/sys/unix"
)

var ErrSocketInUse = errors.New("Unix socket is already accepting connections")

var leaseVerificationHook func(string)
var staleIsolationHook func(stage, path, leasePath, isolationDirectory string)
var preStaleIsolationHook func(stage, path, leasePath, isolationDirectory string)

type processIdentityState uint8

const (
	processActive processIdentityState = iota + 1
	processDead
	processIndeterminate
)

var processIdentityLookup = lookupProcessIdentity

type endpointLock struct {
	file     *os.File
	identity os.FileInfo
	path     string
}

type Listener struct {
	*net.UnixListener
	path          string
	identity      os.FileInfo
	leaseIdentity os.FileInfo
}

func Listen(path string) (*Listener, error) {
	path, err := NormalizePrivatePath(path)
	if err != nil {
		return nil, err
	}
	if err := EnsurePrivateDir(filepath.Dir(path)); err != nil {
		return nil, err
	}
	lock, err := acquireEndpointLock(path)
	if err != nil {
		return nil, err
	}
	defer lock.release()
	if err := removeProvenStaleSocket(path, lock); err != nil {
		return nil, err
	}
	if err := lock.verify(); err != nil {
		return nil, err
	}
	generic, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	listener, ok := generic.(*net.UnixListener)
	if !ok {
		_ = generic.Close()
		return nil, errors.New("Unix listen did not return a Unix listener")
	}
	// The standard library otherwise unlinks the pathname before our inode
	// identity guard can run.
	listener.SetUnlinkOnClose(false)
	info, err := os.Lstat(path)
	if err != nil {
		_ = listener.Close()
		return nil, err
	}
	fail := func(cause error, lease os.FileInfo) (*Listener, error) {
		closeErr := listener.Close()
		cleanupErr := removeCreatedPaths(path, info, lease)
		return nil, errors.Join(cause, closeErr, cleanupErr)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		return fail(err, nil)
	}
	info, err = inspectOwnedSocket(path)
	if err != nil {
		return fail(err, nil)
	}
	if info.Mode().Perm() != 0o600 {
		return fail(fmt.Errorf("socket mode must be 0600, got %04o", info.Mode().Perm()), nil)
	}
	if err := lock.verify(); err != nil {
		return fail(err, nil)
	}
	leaseInfo, err := writeLease(path+".owner", lock)
	if err != nil {
		return fail(err, nil)
	}
	return &Listener{UnixListener: listener, path: path, identity: info, leaseIdentity: leaseInfo}, nil
}

func (l *Listener) Close() error {
	closeErr := l.UnixListener.Close()
	cleanupErr := removeCreatedPaths(l.path, l.identity, l.leaseIdentity)
	return errors.Join(closeErr, cleanupErr)
}

func removeCreatedPaths(path string, socketIdentity, leaseIdentity os.FileInfo) error {
	var result error
	if socketIdentity != nil {
		info, err := os.Lstat(path)
		switch {
		case err == nil:
			if sameFileIdentity(socketIdentity, info) {
				if validateErr := validateOwnedSocket(info); validateErr != nil {
					result = errors.Join(result, validateErr)
				} else if removeErr := os.Remove(path); removeErr != nil {
					result = errors.Join(result, fmt.Errorf("remove owned socket: %w", removeErr))
				}
			}
		case !errors.Is(err, os.ErrNotExist):
			result = errors.Join(result, fmt.Errorf("revalidate owned socket: %w", err))
		}
	}
	if leaseIdentity != nil {
		leasePath := path + ".owner"
		info, err := os.Lstat(leasePath)
		switch {
		case err == nil:
			if sameFileIdentity(leaseIdentity, info) {
				if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || ownerUID(info) != uint32(os.Getuid()) || info.Mode().Perm() != 0o600 {
					result = errors.Join(result, errors.New("ownership lease changed type, owner, or mode before cleanup"))
				} else if removeErr := os.Remove(leasePath); removeErr != nil {
					result = errors.Join(result, fmt.Errorf("remove ownership lease: %w", removeErr))
				}
			}
		case !errors.Is(err, os.ErrNotExist):
			result = errors.Join(result, fmt.Errorf("revalidate ownership lease: %w", err))
		}
	}
	return result
}

func removeProvenStaleSocket(path string, lock *endpointLock) error {
	if lock == nil {
		return errors.New("stale isolation requires the endpoint startup lock")
	}
	if err := lock.verify(); err != nil {
		return err
	}
	first, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if err := validateOwnedSocket(first); err != nil {
		return err
	}
	connection, err := net.DialTimeout("unix", path, 50*time.Millisecond)
	if err == nil {
		_ = connection.Close()
		return ErrSocketInUse
	}
	leasePath := path + ".owner"
	leaseInfo, pid, token, err := inspectLease(leasePath)
	if err != nil {
		return fmt.Errorf("stale socket lacks a valid ownership lease: %w", err)
	}
	switch processIdentityLookup(pid, token) {
	case processActive:
		return ErrSocketInUse
	case processIndeterminate:
		return errors.New("ownership lease process identity is indeterminate")
	case processDead:
		// Only confirmed absence or PID-token replacement permits isolation.
	default:
		return errors.New("ownership lease process identity has an invalid state")
	}
	second, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("revalidate stale socket: %w", err)
	}
	secondLease, err := os.Lstat(leasePath)
	if err != nil || !sameFileIdentity(leaseInfo, secondLease) || !sameFileIdentity(first, second) {
		return errors.New("socket or lease changed during stale-socket validation")
	}
	isolationDirectory, err := os.MkdirTemp(filepath.Dir(path), "."+filepath.Base(path)+".stale-")
	if err != nil {
		return fmt.Errorf("reserve stale socket isolation directory: %w", err)
	}
	stale := filepath.Join(isolationDirectory, filepath.Base(path))
	staleLease := stale + ".owner"
	if preStaleIsolationHook != nil {
		preStaleIsolationHook("socket", path, leasePath, isolationDirectory)
	}
	if err := lock.verify(); err != nil {
		_ = os.Remove(isolationDirectory)
		return err
	}
	if err := revalidateStalePair(path, leasePath, first, leaseInfo); err != nil {
		_ = os.Remove(isolationDirectory)
		return err
	}
	if err := os.Rename(path, stale); err != nil {
		_ = os.Remove(isolationDirectory)
		return fmt.Errorf("isolate stale socket: %w", err)
	}
	if staleIsolationHook != nil {
		staleIsolationHook("socket", path, leasePath, isolationDirectory)
	}
	if preStaleIsolationHook != nil {
		preStaleIsolationHook("lease", path, leasePath, isolationDirectory)
	}
	if err := lock.verify(); err != nil {
		return err
	}
	currentLease, leaseErr := os.Lstat(leasePath)
	if leaseErr != nil || !sameFileIdentity(leaseInfo, currentLease) {
		return errors.New("lease changed before stale isolation")
	}
	if err := os.Rename(leasePath, staleLease); err != nil {
		// Never restore with os.Rename: a concurrent service may already own the
		// original path. The identity-verified socket stays isolated for guarded
		// operator cleanup instead of clobbering that replacement.
		return fmt.Errorf("isolate stale socket lease: %w", err)
	}
	if staleIsolationHook != nil {
		staleIsolationHook("lease", path, leasePath, isolationDirectory)
	}
	isolated, socketErr := os.Lstat(stale)
	isolatedLease, leaseErr := os.Lstat(staleLease)
	if socketErr != nil || leaseErr != nil || !sameFileIdentity(first, isolated) || !sameFileIdentity(leaseInfo, isolatedLease) {
		// Both artifacts remain under the unique owner-private directory. No
		// rollback may overwrite paths installed by a concurrent service.
		return errors.New("stale socket identity changed after isolation")
	}
	if err := os.Remove(staleLease); err != nil {
		return err
	}
	if err := os.Remove(stale); err != nil {
		return err
	}
	return os.Remove(isolationDirectory)
}

func writeLease(path string, lock *endpointLock) (os.FileInfo, error) {
	if lock == nil {
		return nil, errors.New("lease publication requires the endpoint startup lock")
	}
	if err := lock.verify(); err != nil {
		return nil, err
	}
	token, err := processStartToken(os.Getpid())
	if err != nil {
		return nil, fmt.Errorf("read daemon process identity: %w", err)
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return nil, fmt.Errorf("create socket ownership lease: %w", err)
	}
	identity, statErr := file.Stat()
	if statErr != nil {
		_ = file.Close()
		return nil, fmt.Errorf("capture socket ownership lease identity: %w", statErr)
	}
	if err := validateOwnedLease(identity); err != nil {
		_ = file.Close()
		return nil, err
	}
	cleanupFailure := func(cause error) (os.FileInfo, error) {
		cleanupErr := removeOwnedLease(path, identity)
		return nil, errors.Join(cause, cleanupErr)
	}
	if _, err := fmt.Fprintf(file, "%d\n%s\n", os.Getpid(), token); err != nil {
		_ = file.Close()
		return cleanupFailure(err)
	}
	if err := file.Close(); err != nil {
		return cleanupFailure(err)
	}
	if leaseVerificationHook != nil {
		leaseVerificationHook(path)
	}
	info, pid, leaseToken, err := inspectLease(path)
	if err != nil || !sameFileIdentity(identity, info) || pid != os.Getpid() || leaseToken != token {
		return cleanupFailure(errors.New("socket ownership lease verification failed"))
	}
	if err := lock.verify(); err != nil {
		return cleanupFailure(err)
	}
	return info, nil
}

func removeOwnedLease(path string, identity os.FileInfo) error {
	current, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("revalidate ownership lease after failure: %w", err)
	}
	if !sameFileIdentity(identity, current) {
		return errors.New("ownership lease changed before failure cleanup")
	}
	if err := validateOwnedLease(current); err != nil {
		return err
	}
	if err := os.Remove(path); err != nil {
		return fmt.Errorf("remove owned lease after failure: %w", err)
	}
	return nil
}

func acquireEndpointLock(socketPath string) (*endpointLock, error) {
	parent := filepath.Dir(socketPath)
	parentFile, err := securepath.OpenDir(parent, privatePathValidator(os.Getuid()))
	if err != nil {
		return nil, fmt.Errorf("securely walk endpoint lock parent: %w", err)
	}
	defer parentFile.Close()
	name := "." + filepath.Base(socketPath) + ".startup.lock"
	fd, err := unix.Openat(int(parentFile.Fd()), name, unix.O_RDWR|unix.O_CREAT|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open endpoint startup lock: %w", err)
	}
	file := os.NewFile(uintptr(fd), filepath.Join(parent, name))
	if file == nil {
		_ = unix.Close(fd)
		return nil, errors.New("wrap endpoint startup lock")
	}
	fail := func(cause error) (*endpointLock, error) {
		_ = file.Close()
		return nil, cause
	}
	info, err := file.Stat()
	if err != nil {
		return fail(fmt.Errorf("inspect endpoint startup lock: %w", err))
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || ownerUID(info) != uint32(os.Getuid()) {
		return fail(errors.New("endpoint startup lock must be an owner-private 0600 regular file"))
	}
	if err := unix.Flock(fd, unix.LOCK_EX); err != nil {
		return fail(fmt.Errorf("acquire endpoint startup lock: %w", err))
	}
	pathnameInfo, err := os.Lstat(file.Name())
	if err != nil || pathnameInfo.Mode()&os.ModeSymlink != 0 || !sameFileIdentity(info, pathnameInfo) {
		_ = unix.Flock(fd, unix.LOCK_UN)
		return fail(errors.New("endpoint startup lock pathname is ambiguous"))
	}
	return &endpointLock{file: file, identity: info, path: file.Name()}, nil
}

func (l *endpointLock) verify() error {
	if l == nil || l.file == nil {
		return errors.New("endpoint startup lock is unavailable")
	}
	current, err := os.Lstat(l.path)
	if err != nil || current.Mode()&os.ModeSymlink != 0 || !current.Mode().IsRegular() || current.Mode().Perm() != 0o600 || ownerUID(current) != uint32(os.Getuid()) || !sameFileIdentity(l.identity, current) {
		return errors.New("endpoint startup lock pathname is ambiguous")
	}
	return nil
}

func (l *endpointLock) release() {
	if l == nil || l.file == nil {
		return
	}
	current, err := os.Lstat(l.path)
	if err == nil && sameFileIdentity(l.identity, current) {
		_ = unix.Flock(int(l.file.Fd()), unix.LOCK_UN)
	}
	_ = l.file.Close()
}

func revalidateStalePair(path, leasePath string, socketIdentity, leaseIdentity os.FileInfo) error {
	currentSocket, socketErr := os.Lstat(path)
	currentLease, leaseErr := os.Lstat(leasePath)
	if socketErr != nil || leaseErr != nil || !sameFileIdentity(socketIdentity, currentSocket) || !sameFileIdentity(leaseIdentity, currentLease) {
		return errors.New("socket or lease changed before stale isolation")
	}
	return nil
}

func validateOwnedLease(info os.FileInfo) error {
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || ownerUID(info) != uint32(os.Getuid()) || info.Mode().Perm() != 0o600 {
		return errors.New("ownership lease must be an owner-private regular file")
	}
	return nil
}

func inspectLease(path string) (os.FileInfo, int, string, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, 0, "", err
	}
	if err := validateOwnedLease(info); err != nil {
		return nil, 0, "", err
	}
	contents, err := os.ReadFile(path)
	if err != nil {
		return nil, 0, "", err
	}
	lines := strings.Split(strings.TrimSpace(string(contents)), "\n")
	if len(lines) != 2 || len(lines[1]) > 128 {
		return nil, 0, "", errors.New("malformed ownership lease")
	}
	pid, err := strconv.Atoi(lines[0])
	if err != nil || pid <= 0 {
		return nil, 0, "", errors.New("malformed ownership lease pid")
	}
	return info, pid, lines[1], nil
}

func inspectOwnedSocket(path string) (os.FileInfo, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if err := validateOwnedSocket(info); err != nil {
		return nil, err
	}
	return info, nil
}

func validateOwnedSocket(info os.FileInfo) error {
	if info.Mode()&os.ModeSymlink != 0 || info.Mode()&os.ModeSocket == 0 {
		return errors.New("socket path must be a non-symlink Unix socket")
	}
	if ownerUID(info) != uint32(os.Getuid()) {
		return errors.New("socket has foreign ownership")
	}
	if info.Mode().Perm()&0o077 != 0 {
		return errors.New("socket is accessible by group or other users")
	}
	return nil
}
