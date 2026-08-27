package config

import (
	"os"
	"syscall"
	"testing"
	"time"
)

type directoryInfo struct {
	mode os.FileMode
	uid  uint32
}

func (info directoryInfo) Name() string       { return "directory" }
func (info directoryInfo) Size() int64        { return 0 }
func (info directoryInfo) Mode() os.FileMode  { return os.ModeDir | info.mode }
func (info directoryInfo) ModTime() time.Time { return time.Time{} }
func (info directoryInfo) IsDir() bool        { return true }
func (info directoryInfo) Sys() any           { return &syscall.Stat_t{Uid: info.uid} }

func TestConfigPathValidatorOwnershipAndModePolicy(t *testing.T) {
	uid := os.Getuid()
	foreignUID := uint32(uid + 1)
	tests := []struct {
		name    string
		info    directoryInfo
		final   bool
		wantErr bool
	}{
		{"owner-private final", directoryInfo{mode: 0o700, uid: uint32(uid)}, true, false},
		{"foreign final", directoryInfo{mode: 0o700, uid: foreignUID}, true, true},
		{"widened final", directoryInfo{mode: 0o755, uid: uint32(uid)}, true, true},
		{"read-only foreign ancestor", directoryInfo{mode: 0o755, uid: foreignUID}, false, true},
		{"group-writable ancestor", directoryInfo{mode: 0o770, uid: uint32(uid)}, false, true},
		{"world-writable ancestor", directoryInfo{mode: 0o777, uid: uint32(uid)}, false, true},
		{"sticky foreign ancestor", directoryInfo{mode: os.ModeSticky | 0o777, uid: foreignUID}, false, true},
		{"sticky root ancestor", directoryInfo{mode: os.ModeSticky | 0o777, uid: 0}, false, false},
		{"sticky owner ancestor", directoryInfo{mode: os.ModeSticky | 0o777, uid: uint32(uid)}, false, false},
	}
	validator := configPathValidator(uid)
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validator("/ancestor", test.info, test.final)
			if (err != nil) != test.wantErr {
				t.Fatalf("unexpected validation result: %v", err)
			}
		})
	}
}
