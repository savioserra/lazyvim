package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func loadManifest(t *testing.T) Values {
	t.Helper()
	file, err := os.Open(filepath.Join("..", "..", "manifests", "tools.env"))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	values, err := Parse(file)
	if err != nil {
		t.Fatal(err)
	}
	return values
}

func TestCatalogCoversSupportedPlatforms(t *testing.T) {
	values := loadManifest(t)
	for _, platform := range SupportedPlatforms() {
		platform := platform
		t.Run(platform.ID, func(t *testing.T) {
			catalog, err := NewCatalog(values, platform)
			if err != nil {
				t.Fatal(err)
			}
			if len(catalog.Releases) != 7 {
				t.Fatalf("got %d releases, want 7", len(catalog.Releases))
			}
			seen := map[string]bool{}
			for _, release := range catalog.Releases {
				if seen[release.Name] {
					t.Fatalf("duplicate release %s", release.Name)
				}
				seen[release.Name] = true
				if release.URL == "" || len(release.SHA256) != 64 || release.ExpectedBinary == "" || release.ArchiveName == "" {
					t.Fatalf("incomplete release: %+v", release)
				}
			}
			if catalog.Font.URL == "" || len(catalog.Font.SHA256) != 64 {
				t.Fatalf("incomplete font: %+v", catalog.Font)
			}
		})
	}
}

func TestCatalogPlatformLayouts(t *testing.T) {
	values := loadManifest(t)
	tests := map[string]struct {
		nvimPrefix string
		fzfBinary  string
		treeBinary string
	}{
		"linux-x86_64":   {"nvim-linux-x86_64", "bin/fzf", "bin/tree-sitter"},
		"darwin-arm64":   {"nvim-macos-arm64", "bin/fzf", "bin/tree-sitter"},
		"darwin-x86_64":  {"nvim-macos-x86_64", "bin/fzf", "bin/tree-sitter"},
		"windows-arm64":  {"nvim-win-arm64", "fzf.exe", "tree-sitter.exe"},
		"windows-x86_64": {"nvim-win64", "fzf.exe", "tree-sitter.exe"},
	}
	for _, platform := range SupportedPlatforms() {
		catalog, err := NewCatalog(values, platform)
		if err != nil {
			t.Fatal(err)
		}
		expected := tests[platform.ID]
		nvim, _ := catalog.Release("nvim")
		fzf, _ := catalog.Release("fzf")
		tree, _ := catalog.Release("tree-sitter")
		if nvim.StripPrefix != expected.nvimPrefix || fzf.ExpectedBinary != expected.fzfBinary || tree.ExpectedBinary != expected.treeBinary {
			t.Fatalf("%s layout mismatch: nvim=%q fzf=%q tree=%q", platform.ID, nvim.StripPrefix, fzf.ExpectedBinary, tree.ExpectedBinary)
		}
	}
}

func TestPlatformForRejectsUnsupportedHost(t *testing.T) {
	if _, err := PlatformFor("linux", "arm64"); err == nil {
		t.Fatal("expected Linux ARM64 to be rejected")
	}
}

func TestParseRejectsNonLiteralManifestValues(t *testing.T) {
	if _, err := Parse(strings.NewReader("VERSION=$(bad)\n")); err == nil {
		t.Fatal("expected invalid manifest to fail")
	}
}

func TestParseRejectsDuplicateKeys(t *testing.T) {
	if _, err := Parse(strings.NewReader("VERSION=\"1\"\nVERSION=\"2\"\n")); err == nil {
		t.Fatal("expected duplicate manifest key to fail")
	}
}
