//go:build linux || darwin

package state

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/savioserra/lazyvim/services/subagents/internal/securepath"
	"golang.org/x/sys/unix"
)

const MaxRecords = 4096
const MaxRecordBytes = 1024 * 1024

type CrashPoint string

const (
	CrashBeforeRename  CrashPoint = "before-rename"
	CrashAfterRename   CrashPoint = "after-rename-before-directory-fsync"
	CrashBeforeReceipt CrashPoint = "before-receipt"
)

type Store struct {
	Directory string
	Crash     func(CrashPoint) error
}

func New(directory string) (*Store, error) {
	s := &Store{Directory: directory}
	d, err := securepath.EnsureDir(directory, 0o700, privateValidator)
	if err != nil {
		return nil, err
	}
	defer d.Close()
	return s, nil
}
func privateValidator(path string, info os.FileInfo, final bool) error {
	stat := info.Sys().(*syscall.Stat_t)
	if final {
		if stat.Uid != uint32(os.Getuid()) || info.Mode().Perm() != 0o700 {
			return fmt.Errorf("durable state directory %s must be owner-private 0700", path)
		}
		return nil
	}
	if stat.Uid != 0 && stat.Uid != uint32(os.Getuid()) {
		return fmt.Errorf("durable state ancestor %s is foreign", path)
	}
	if info.Mode().Perm()&0o022 != 0 && info.Mode()&os.ModeSticky == 0 && stat.Uid != uint32(os.Getuid()) {
		return fmt.Errorf("foreign durable state ancestor %s is writable without sticky bit", path)
	}
	return nil
}
func recordName(agentID string) string {
	sum := sha256.Sum256([]byte(agentID))
	return hex.EncodeToString(sum[:16]) + ".json"
}
func temporaryRecordName(name string) bool {
	if len(name) != len(".state-")+16 || !strings.HasPrefix(name, ".state-") {
		return false
	}
	_, err := hex.DecodeString(strings.TrimPrefix(name, ".state-"))
	return err == nil
}
func (s *Store) Save(ctx context.Context, record application.DurableHostedRecord) error {
	if err := validateRecord(record); err != nil {
		return err
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
	}
	encoded, err := json.Marshal(record)
	if err != nil {
		return err
	}
	encoded = append(encoded, '\n')
	if len(encoded) > MaxRecordBytes {
		return errors.New("durable hosted record exceeds size bound")
	}
	dir, err := securepath.OpenDir(s.Directory, privateValidator)
	if err != nil {
		return err
	}
	defer dir.Close()
	var nonce [8]byte
	if _, err = rand.Read(nonce[:]); err != nil {
		return err
	}
	temporary := ".state-" + hex.EncodeToString(nonce[:])
	fd, err := unix.Openat(int(dir.Fd()), temporary, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0o600)
	if err != nil {
		return err
	}
	file := os.NewFile(uintptr(fd), temporary)
	cleanup := true
	defer func() {
		file.Close()
		if cleanup {
			_ = unix.Unlinkat(int(dir.Fd()), temporary, 0)
		}
	}()
	if _, err = file.Write(encoded); err != nil {
		return err
	}
	if err = file.Sync(); err != nil {
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	if s.Crash != nil {
		if err = s.Crash(CrashBeforeRename); err != nil {
			return err
		}
	}
	if err = unix.Renameat(int(dir.Fd()), temporary, int(dir.Fd()), recordName(record.AgentID)); err != nil {
		return err
	}
	cleanup = false
	if s.Crash != nil {
		if err = s.Crash(CrashAfterRename); err != nil {
			return err
		}
	}
	if err = dir.Sync(); err != nil {
		return err
	}
	if s.Crash != nil {
		if err = s.Crash(CrashBeforeReceipt); err != nil {
			return err
		}
	}
	return nil
}
func (s *Store) Remove(ctx context.Context, agentID string) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
	}
	dir, err := securepath.OpenDir(s.Directory, privateValidator)
	if err != nil {
		return err
	}
	defer dir.Close()
	if err = unix.Unlinkat(int(dir.Fd()), recordName(agentID), 0); err != nil && !errors.Is(err, unix.ENOENT) {
		return err
	}
	return dir.Sync()
}
func (s *Store) LoadAll(ctx context.Context) ([]application.DurableHostedRecord, error) {
	dir, err := securepath.OpenDir(s.Directory, privateValidator)
	if err != nil {
		return nil, err
	}
	defer dir.Close()
	entries, err := dir.Readdirnames(MaxRecords + 1)
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}
	if len(entries) > MaxRecords {
		return nil, errors.New("durable hosted state entry count exceeds bound")
	}
	records := make([]application.DurableHostedRecord, 0, len(entries))
	removedTemporary := false
	for _, name := range entries {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}
		if temporaryRecordName(name) {
			if err := unix.Unlinkat(int(dir.Fd()), name, 0); err != nil {
				return nil, fmt.Errorf("remove interrupted durable state temporary %q: %w", name, err)
			}
			removedTemporary = true
			continue
		}
		if len(records) >= MaxRecords {
			return nil, errors.New("durable hosted record count exceeds bound")
		}
		if len(name) != 37 || !strings.HasSuffix(name, ".json") {
			return nil, fmt.Errorf("unexpected durable state entry %q", name)
		}
		fd, err := unix.Openat(int(dir.Fd()), name, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		if err != nil {
			return nil, fmt.Errorf("open durable state entry %q: %w", name, err)
		}
		file := os.NewFile(uintptr(fd), name)
		info, statErr := file.Stat()
		if statErr != nil {
			file.Close()
			return nil, statErr
		}
		stat := info.Sys().(*syscall.Stat_t)
		if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || stat.Uid != uint32(os.Getuid()) || info.Size() > MaxRecordBytes {
			file.Close()
			return nil, fmt.Errorf("durable state entry %q is unsafe", name)
		}
		contents, readErr := io.ReadAll(io.LimitReader(file, MaxRecordBytes+1))
		file.Close()
		if readErr != nil {
			return nil, readErr
		}
		var record application.DurableHostedRecord
		if err = json.Unmarshal(contents, &record); err != nil {
			return nil, fmt.Errorf("decode durable state entry %q: %w", name, err)
		}
		if err = validateRecord(record); err != nil {
			return nil, fmt.Errorf("validate durable state entry %q: %w", name, err)
		}
		if recordName(record.AgentID) != name {
			return nil, fmt.Errorf("durable state filename identity mismatch")
		}
		records = append(records, record)
	}
	if removedTemporary {
		if err := dir.Sync(); err != nil {
			return nil, err
		}
	}
	return records, nil
}
func validateRecord(r application.DurableHostedRecord) error {
	if r.SchemaVersion != application.DurableHostedSchemaVersion {
		return fmt.Errorf("unsupported durable hosted schema %d", r.SchemaVersion)
	}
	if r.OwnerUID != os.Getuid() {
		return errors.New("durable hosted record owner mismatch")
	}
	if r.AgentID == "" || len(r.AgentID) > 64 || r.Session.SessionID == "" || r.Session.GenerationID == "" || r.Session.Caller != "hosted:"+r.AgentID || !r.Session.Persistent || !r.Session.ExpiresAt.IsZero() || r.LaunchSpec.AgentID != r.AgentID || r.Binding.RuntimeID != r.LaunchSpec.RuntimeID || r.Binding.Incarnation != r.LaunchSpec.Incarnation {
		return errors.New("durable hosted record identity mismatch")
	}
	if len(r.AllowedCapabilities) > 16 || len(r.Session.Capabilities) > 16 || len(r.AgentState.Attachments) > 4096 || len(r.AgentState.Revoked) > 4096 || len(r.AgentState.BridgeDeliveries) > 256 || len(r.AgentState.DeliverySources) > 256 || len(r.AgentState.MutationScopes) > 256 {
		return errors.New("durable hosted record collection bound exceeded")
	}
	scopeKeys := make(map[string]struct{}, len(r.AgentState.MutationScopes))
	for _, scope := range r.AgentState.MutationScopes {
		expectedKey := fmt.Sprintf("%d:%s%d:%s%d:%s:%d:%d", len(scope.SessionID), scope.SessionID, len(scope.GenerationID), scope.GenerationID, len(scope.Principal), scope.Principal, scope.Fence, scope.Incarnation)
		if scope.Key == "" || scope.Key != expectedKey || len(scope.Key) > 4096 || len(scope.Results) > 1280 || len(scope.Dedupe) > 256 || len(scope.Chains) > 256 {
			return errors.New("durable mutation scope bound or identity mismatch")
		}
		if _, duplicate := scopeKeys[scope.Key]; duplicate {
			return errors.New("duplicate durable mutation scope")
		}
		scopeKeys[scope.Key] = struct{}{}
	}
	deliveries := make(map[uint64]struct{}, len(r.AgentState.BridgeDeliveries))
	for _, delivery := range r.AgentState.BridgeDeliveries {
		if delivery.Sequence == 0 || delivery.DedupeID == "" {
			return errors.New("durable delivery identity is invalid")
		}
		if _, duplicate := deliveries[delivery.Sequence]; duplicate {
			return errors.New("duplicate durable delivery sequence")
		}
		deliveries[delivery.Sequence] = struct{}{}
		key, exists := r.AgentState.DeliverySources[delivery.Sequence]
		if !exists {
			return errors.New("durable delivery source is missing")
		}
		if _, exists := scopeKeys[key]; !exists {
			return errors.New("durable delivery source scope is missing")
		}
	}
	if len(deliveries) != len(r.AgentState.DeliverySources) {
		return errors.New("durable delivery source cardinality mismatch")
	}
	for _, value := range []string{r.AgentID, r.Session.SessionID, r.Session.GenerationID, r.Session.Caller, r.Session.CredentialFile, r.LaunchSpec.RuntimeID, r.LaunchSpec.TmuxSession, r.LaunchSpec.TmuxWindow, r.LaunchSpec.PiSessionDirectory, r.LaunchSpec.PiSessionName, r.RuntimeConfig.ProjectDirectory} {
		if value == "" || len(value) > 4096 || value != strings.TrimSpace(value) || strings.ContainsAny(value, "\x00\r\n") {
			return errors.New("durable hosted record contains invalid text")
		}
	}
	if !filepath.IsAbs(r.Session.CredentialFile) || !filepath.IsAbs(r.LaunchSpec.PiSessionDirectory) || !filepath.IsAbs(r.RuntimeConfig.ProjectDirectory) {
		return errors.New("durable hosted paths must be absolute")
	}
	return nil
}
