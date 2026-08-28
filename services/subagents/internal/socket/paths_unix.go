//go:build linux || darwin

package socket

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/savioserra/lazyvim/services/subagents/internal/securepath"
)

type Paths struct {
	RuntimeDir string
	StateDir   string
	ConfigFile string
	SocketFile string
}

func ResolvePaths() (Paths, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return Paths{}, err
	}
	workingDirectory, err := os.Getwd()
	if err != nil {
		return Paths{}, err
	}
	uid := os.Getuid()
	runtimeRoot := os.Getenv("XDG_RUNTIME_DIR")
	fallbackRuntime := runtimeRoot == ""
	if fallbackRuntime {
		tempRoot := envOr("TMPDIR", os.TempDir())
		runtimeRoot = filepath.Join(tempRoot, "workstation-subagents-"+strconv.Itoa(uid))
	}
	stateRoot := envOr("XDG_STATE_HOME", filepath.Join(home, ".local", "state"))
	configRoot := envOr("XDG_CONFIG_HOME", filepath.Join(home, ".config"))
	roots := []*string{&runtimeRoot, &stateRoot, &configRoot}
	for _, root := range roots {
		normalized, normalizeErr := normalizePrivatePathAt(workingDirectory, *root)
		if normalizeErr != nil {
			return Paths{}, fmt.Errorf("private runtime/state/config path: %w", normalizeErr)
		}
		*root = normalized
	}
	if fallbackRuntime {
		if err := ensurePredictableRuntimeRoot(runtimeRoot, uid); err != nil {
			return Paths{}, fmt.Errorf("unsafe fallback runtime root: %w", err)
		}
	} else if err := validatePrivateDirectory(runtimeRoot, uid); err != nil {
		return Paths{}, fmt.Errorf("unsafe XDG_RUNTIME_DIR: %w", err)
	}
	runtimeDir := filepath.Join(runtimeRoot, "ws-subagents")
	paths := Paths{
		RuntimeDir: runtimeDir,
		StateDir:   filepath.Join(stateRoot, "workstation", "subagents"),
		ConfigFile: filepath.Join(configRoot, "workstation", "subagents", "config.toml"),
		SocketFile: filepath.Join(runtimeDir, "control.sock"),
	}
	if len(paths.SocketFile) > 100 {
		return Paths{}, errors.New("Unix socket path exceeds the portable 100-byte limit")
	}
	return paths, nil
}

// NormalizePrivatePath resolves a caller-provided path before policy checks or
// filesystem use. Relative paths are interpreted from the process working directory.
func NormalizePrivatePath(path string) (string, error) {
	workingDirectory, err := os.Getwd()
	if err != nil {
		return "", err
	}
	return normalizePrivatePathAt(workingDirectory, path)
}

func normalizePrivatePathAt(workingDirectory, path string) (string, error) {
	if path == "" {
		return "", errors.New("private path must not be empty")
	}
	if !filepath.IsAbs(path) {
		path = filepath.Join(workingDirectory, path)
	}
	path = filepath.Clean(path)
	if !filepath.IsAbs(path) {
		return "", errors.New("private path must resolve to an absolute path")
	}
	if isWindowsMount(path) {
		return "", errors.New("private paths must not be placed on a Windows-mounted filesystem")
	}
	return path, nil
}

func EnsurePrivateDir(path string) error {
	return ensurePrivateDir(path, privatePathValidator(os.Getuid()))
}

// EnsureOwnedPrivateDir permits a writable ancestor only when that ancestor is
// owned by the current uid. Descriptor-relative traversal keeps subsequent
// creation and opens bound to the validated inode while the final directory
// remains owner-private 0700.
func EnsureOwnedPrivateDir(path string) error {
	return ensurePrivateDir(path, ownedPrivatePathValidator(os.Getuid()))
}

func ensurePrivateDir(path string, validator securepath.DirValidator) error {
	path, err := NormalizePrivatePath(path)
	if err != nil {
		return err
	}
	if path == "/" {
		return errors.New("cannot create filesystem root")
	}
	if info, statErr := os.Lstat(path); statErr == nil {
		if err := validatePrivateDirectoryInfo(info, os.Getuid()); err != nil {
			return err
		}
		file, err := securepath.OpenDir(path, validator)
		if file != nil {
			_ = file.Close()
		}
		return err
	} else if !errors.Is(statErr, os.ErrNotExist) {
		return statErr
	}
	file, err := securepath.EnsureDir(path, 0o700, validator)
	if file != nil {
		_ = file.Close()
	}
	return err
}

func ensurePredictableRuntimeRoot(path string, uid int) error {
	if info, statErr := os.Lstat(path); statErr == nil {
		if err := validatePrivateDirectoryInfo(info, uid); err != nil {
			return err
		}
		file, err := securepath.OpenDir(path, privatePathValidator(uid))
		if file != nil {
			_ = file.Close()
		}
		return err
	} else if !errors.Is(statErr, os.ErrNotExist) {
		return statErr
	}
	file, err := securepath.EnsureDir(path, 0o700, privatePathValidator(uid))
	if file != nil {
		_ = file.Close()
	}
	return err
}

func validatePrivateDirectory(path string, uid int) error {
	file, err := securepath.OpenDir(path, privatePathValidator(uid))
	if file != nil {
		_ = file.Close()
	}
	return err
}

func privatePathValidator(uid int) securepath.DirValidator {
	return func(path string, info os.FileInfo, final bool) error {
		if final {
			return validatePrivateDirectoryInfo(info, uid)
		}
		mode := info.Mode().Perm()
		if mode&0o022 != 0 && info.Mode()&os.ModeSticky == 0 {
			return fmt.Errorf("runtime ancestor %s is writable without the sticky bit (mode %04o)", path, mode)
		}
		return nil
	}
}

func ownedPrivatePathValidator(uid int) securepath.DirValidator {
	return func(path string, info os.FileInfo, final bool) error {
		if final {
			return validatePrivateDirectoryInfo(info, uid)
		}
		owner := ownerUID(info)
		if owner != 0 && owner != uint32(uid) {
			return fmt.Errorf("private ancestor %s has foreign ownership", path)
		}
		mode := info.Mode().Perm()
		if mode&0o022 != 0 && info.Mode()&os.ModeSticky == 0 && owner != uint32(uid) {
			return fmt.Errorf("foreign private ancestor %s is writable without the sticky bit (mode %04o)", path, mode)
		}
		return nil
	}
}

func validatePrivateDirectoryInfo(info os.FileInfo, uid int) error {
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return errors.New("path must be a non-symlink directory")
	}
	if ownerUID(info) != uint32(uid) {
		return errors.New("directory has foreign ownership")
	}
	if info.Mode().Perm() != 0o700 {
		return fmt.Errorf("directory mode must be 0700, got %04o", info.Mode().Perm())
	}
	return nil
}

func ownerUID(info os.FileInfo) uint32 { return info.Sys().(*syscall.Stat_t).Uid }

func sameFileIdentity(a, b os.FileInfo) bool {
	left := a.Sys().(*syscall.Stat_t)
	right := b.Sys().(*syscall.Stat_t)
	return left.Dev == right.Dev && left.Ino == right.Ino && left.Uid == right.Uid
}

func isWindowsMount(path string) bool {
	clean := filepath.Clean(path)
	return clean == "/mnt" || strings.HasPrefix(clean, "/mnt/")
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
