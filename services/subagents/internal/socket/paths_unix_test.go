//go:build linux || darwin

package socket

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRelativeXDGRootsAreNormalizedBeforeWindowsMountPolicy(t *testing.T) {
	for _, root := range []string{"runtime", "state", "config"} {
		if _, err := normalizePrivatePathAt("/mnt/c/workstation", root); err == nil {
			t.Fatalf("relative XDG root %q bypassed /mnt policy", root)
		}
	}
	normalized, err := normalizePrivatePathAt("/tmp/workstation", "runtime")
	if err != nil {
		t.Fatal(err)
	}
	if normalized != "/tmp/workstation/runtime" || !filepath.IsAbs(normalized) {
		t.Fatalf("relative XDG root was not normalized: %q", normalized)
	}
}

func TestEnsurePrivateDirRejectsIntermediateSymlinkToWindowsMount(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "mounted-link")
	if err := os.Symlink("/mnt", link); err != nil {
		t.Fatal(err)
	}
	if err := EnsurePrivateDir(filepath.Join(link, "workstation", "runtime")); err == nil {
		t.Fatal("accepted socket directory with intermediate symlink to /mnt")
	}
}

func TestResolvePathsCreatesOrValidatesPredictableFallbackRoot(t *testing.T) {
	temp, err := os.MkdirTemp("/tmp", "wsp-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(temp) })
	if err := os.Chmod(temp, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMPDIR", temp)
	t.Setenv("XDG_RUNTIME_DIR", "")
	paths, err := ResolvePaths()
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Dir(paths.RuntimeDir)
	info, err := os.Lstat(root)
	if err != nil {
		t.Fatal(err)
	}
	if !info.IsDir() || info.Mode().Perm() != 0o700 {
		t.Fatalf("fallback root is not exact 0700: %#v", info.Mode())
	}
}

func TestResolvePathsRejectsAttackerPrecreatedFallbackRootAndUnsafeAncestor(t *testing.T) {
	for _, test := range []struct {
		name                   string
		ancestorMode, rootMode os.FileMode
		precreateRoot          bool
	}{
		{name: "widened root", ancestorMode: 0o700, rootMode: 0o777, precreateRoot: true},
		{name: "writable ancestor", ancestorMode: 0o777, rootMode: 0, precreateRoot: false},
	} {
		t.Run(test.name, func(t *testing.T) {
			temp, err := os.MkdirTemp("/tmp", "wsp-")
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = os.RemoveAll(temp) })
			if err := os.Chmod(temp, test.ancestorMode); err != nil {
				t.Fatal(err)
			}
			t.Setenv("TMPDIR", temp)
			t.Setenv("XDG_RUNTIME_DIR", "")
			root := filepath.Join(temp, "workstation-subagents-"+itoa(os.Getuid()))
			if test.precreateRoot {
				if err := os.Mkdir(root, test.rootMode); err != nil {
					t.Fatal(err)
				}
				if err := os.Chmod(root, test.rootMode); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := ResolvePaths(); err == nil {
				t.Fatal("accepted unsafe predictable fallback root")
			}
		})
	}
}

func itoa(value int) string {
	if value == 0 {
		return "0"
	}
	var digits [32]byte
	index := len(digits)
	for value > 0 {
		index--
		digits[index] = byte('0' + value%10)
		value /= 10
	}
	return string(digits[index:])
}
