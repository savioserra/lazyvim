//go:build linux || darwin

// Package securepath provides descriptor-relative, no-follow traversal for
// security-sensitive absolute Unix directory paths.
package securepath

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

// DirValidator validates each opened directory descriptor. final is true only
// for the requested directory; no path component is ever followed as a symlink.
type DirValidator func(path string, info os.FileInfo, final bool) error

// OpenDir walks an existing absolute directory one component at a time.
func OpenDir(path string, validate DirValidator) (*os.File, error) {
	return walkDir(path, false, 0, validate)
}

// EnsureDir walks an absolute directory and creates missing components with
// mode. Creation and subsequent opens are relative to already validated FDs.
func EnsureDir(path string, mode os.FileMode, validate DirValidator) (*os.File, error) {
	return walkDir(path, true, mode, validate)
}

func walkDir(path string, create bool, mode os.FileMode, validate DirValidator) (*os.File, error) {
	clean := filepath.Clean(path)
	if !filepath.IsAbs(clean) {
		return nil, errors.New("secure directory path must be absolute")
	}
	fd, err := unix.Open("/", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, fmt.Errorf("open filesystem root: %w", err)
	}
	current := os.NewFile(uintptr(fd), "/")
	if current == nil {
		_ = unix.Close(fd)
		return nil, errors.New("wrap filesystem root descriptor")
	}
	components := strings.FieldsFunc(strings.TrimPrefix(clean, "/"), func(r rune) bool { return r == '/' })
	if len(components) == 0 {
		if err := validateDescriptor(current, "/", true, validate); err != nil {
			_ = current.Close()
			return nil, err
		}
		return current, nil
	}
	currentPath := ""
	for index, component := range components {
		currentPath = filepath.Join(currentPath, "/", component)
		nextFD, openErr := unix.Openat(int(current.Fd()), component, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		if openErr != nil && create && errors.Is(openErr, unix.ENOENT) {
			if mkdirErr := unix.Mkdirat(int(current.Fd()), component, uint32(mode.Perm())); mkdirErr != nil && !errors.Is(mkdirErr, unix.EEXIST) {
				_ = current.Close()
				return nil, fmt.Errorf("create secure directory %s: %w", currentPath, mkdirErr)
			}
			nextFD, openErr = unix.Openat(int(current.Fd()), component, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		}
		if openErr != nil {
			_ = current.Close()
			return nil, fmt.Errorf("open secure directory component %s: %w", currentPath, openErr)
		}
		next := os.NewFile(uintptr(nextFD), currentPath)
		if next == nil {
			_ = unix.Close(nextFD)
			_ = current.Close()
			return nil, fmt.Errorf("wrap secure directory component %s", currentPath)
		}
		_ = current.Close()
		current = next
		if err := validateDescriptor(current, currentPath, index == len(components)-1, validate); err != nil {
			_ = current.Close()
			return nil, err
		}
	}
	return current, nil
}

func validateDescriptor(file *os.File, path string, final bool, validate DirValidator) error {
	info, err := file.Stat()
	if err != nil {
		return fmt.Errorf("inspect secure directory %s: %w", path, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("secure path component %s is not a directory", path)
	}
	if validate != nil {
		if err := validate(path, info, final); err != nil {
			return err
		}
	}
	return nil
}
