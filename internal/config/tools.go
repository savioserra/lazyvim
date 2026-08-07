package config

import (
	"bufio"
	"encoding/hex"
	"fmt"
	"io"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
)

type Values map[string]string

func Parse(r io.Reader) (Values, error) {
	values := Values{}
	scanner := bufio.NewScanner(r)
	for line := 1; scanner.Scan(); line++ {
		text := strings.TrimSpace(scanner.Text())
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		key, value, ok := strings.Cut(text, "=")
		if !ok || key == "" || value == "" || value[0] != '"' || value[len(value)-1] != '"' {
			return nil, fmt.Errorf("invalid tool manifest line %d", line)
		}
		key = strings.TrimSpace(key)
		for _, char := range key {
			if !(char == '_' || char >= 'A' && char <= 'Z' || char >= '0' && char <= '9') {
				return nil, fmt.Errorf("invalid tool manifest key %q on line %d", key, line)
			}
		}
		if _, exists := values[key]; exists {
			return nil, fmt.Errorf("duplicate tool manifest key %q on line %d", key, line)
		}
		values[key] = value[1 : len(value)-1]
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read tool manifest: %w", err)
	}
	return values, nil
}

func (v Values) Require(keys ...string) error {
	var missing []string
	for _, key := range keys {
		if strings.TrimSpace(v[key]) == "" {
			missing = append(missing, key)
		}
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		return fmt.Errorf("tool manifest is missing: %s", strings.Join(missing, ", "))
	}
	return nil
}

type Platform struct {
	ID     string
	GOOS   string
	GOARCH string
}

func CurrentPlatform() (Platform, error) {
	architecture := runtime.GOARCH
	if runtime.GOOS == "windows" {
		native := strings.ToUpper(strings.TrimSpace(os.Getenv("PROCESSOR_ARCHITEW6432")))
		if native == "" {
			native = strings.ToUpper(strings.TrimSpace(os.Getenv("PROCESSOR_ARCHITECTURE")))
		}
		switch native {
		case "ARM64", "AARCH64":
			architecture = "arm64"
		case "AMD64", "X86_64":
			architecture = "amd64"
		}
	}
	return PlatformFor(runtime.GOOS, architecture)
}

func PlatformFor(goos, goarch string) (Platform, error) {
	switch goos + "/" + goarch {
	case "linux/amd64":
		return Platform{ID: "linux-x86_64", GOOS: goos, GOARCH: goarch}, nil
	case "darwin/arm64":
		return Platform{ID: "darwin-arm64", GOOS: goos, GOARCH: goarch}, nil
	case "darwin/amd64":
		return Platform{ID: "darwin-x86_64", GOOS: goos, GOARCH: goarch}, nil
	case "windows/arm64":
		return Platform{ID: "windows-arm64", GOOS: goos, GOARCH: goarch}, nil
	case "windows/amd64":
		return Platform{ID: "windows-x86_64", GOOS: goos, GOARCH: goarch}, nil
	default:
		return Platform{}, fmt.Errorf("unsupported platform: %s/%s", goos, goarch)
	}
}

func SupportedPlatforms() []Platform {
	platforms := make([]Platform, 0, 5)
	for _, pair := range [][2]string{{"linux", "amd64"}, {"darwin", "arm64"}, {"darwin", "amd64"}, {"windows", "arm64"}, {"windows", "amd64"}} {
		platform, _ := PlatformFor(pair[0], pair[1])
		platforms = append(platforms, platform)
	}
	return platforms
}

type ArchiveKind string

const (
	ArchiveTarGz ArchiveKind = "tar.gz"
	ArchiveTarXz ArchiveKind = "tar.xz"
	ArchiveZip   ArchiveKind = "zip"
)

type Release struct {
	Name              string
	Version           string
	Platform          Platform
	URL               string
	SHA256            string
	ArchiveName       string
	ArchiveKind       ArchiveKind
	TargetName        string
	StripPrefix       string
	DestinationPrefix string
	ExpectedBinary    string
}

func (r Release) ReleaseIdentity() string { return r.Platform.ID + ":" + r.SHA256 }
func (r Release) ExecutableName() string  { return filepath.Base(filepath.FromSlash(r.ExpectedBinary)) }

type Font struct {
	Version     string
	URL         string
	SHA256      string
	ArchiveName string
	ArchiveKind ArchiveKind
}

type Catalog struct {
	Platform Platform
	Tools    Values
	Releases []Release
	Font     Font
}

type catalogPlatformSpec struct {
	manifestKey   string
	executableExt string
	toolArchive   ArchiveKind
	neovimPrefix  string
	ripgrepSuffix string
	fdSuffix      string
	binaryPrefix  string
}

var catalogPlatforms = map[string]catalogPlatformSpec{
	"linux-x86_64": {
		manifestKey: "LINUX_X86_64", toolArchive: ArchiveTarGz,
		neovimPrefix: "nvim-linux-x86_64", ripgrepSuffix: "x86_64-unknown-linux-musl",
		fdSuffix: "x86_64-unknown-linux-gnu", binaryPrefix: "bin",
	},
	"darwin-arm64": {
		manifestKey: "DARWIN_ARM64", toolArchive: ArchiveTarGz,
		neovimPrefix: "nvim-macos-arm64", ripgrepSuffix: "aarch64-apple-darwin",
		fdSuffix: "aarch64-apple-darwin", binaryPrefix: "bin",
	},
	"darwin-x86_64": {
		manifestKey: "DARWIN_X86_64", toolArchive: ArchiveTarGz,
		neovimPrefix: "nvim-macos-x86_64", ripgrepSuffix: "x86_64-apple-darwin",
		fdSuffix: "x86_64-apple-darwin", binaryPrefix: "bin",
	},
	"windows-arm64": {
		manifestKey: "WINDOWS_ARM64", executableExt: ".exe", toolArchive: ArchiveZip,
		neovimPrefix: "nvim-win-arm64", ripgrepSuffix: "aarch64-pc-windows-msvc",
		fdSuffix: "aarch64-pc-windows-msvc",
	},
	"windows-x86_64": {
		manifestKey: "WINDOWS_X86_64", executableExt: ".exe", toolArchive: ArchiveZip,
		neovimPrefix: "nvim-win64", ripgrepSuffix: "x86_64-pc-windows-msvc",
		fdSuffix: "x86_64-pc-windows-msvc",
	},
}

type releaseSpec struct {
	name        string
	manifest    string
	version     string
	archiveKind ArchiveKind
	stripPrefix string
	destination string
	expected    string
}

func NewCatalog(values Values, platform Platform) (Catalog, error) {
	platformSpec, ok := catalogPlatforms[platform.ID]
	if !ok {
		return Catalog{}, fmt.Errorf("unsupported catalog platform: %s", platform.ID)
	}
	fdVersionKey := "FD_" + platformSpec.manifestKey + "_VERSION"
	versionKeys := []string{
		"NEOVIM_VERSION", "CHEZMOI_VERSION", "RIPGREP_VERSION", fdVersionKey,
		"FZF_VERSION", "LAZYGIT_VERSION", "TREE_SITTER_VERSION", "NERD_FONT_VERSION",
	}
	if err := values.Require(versionKeys...); err != nil {
		return Catalog{}, err
	}

	fdVersion := values[fdVersionKey]
	specs := []releaseSpec{
		{name: "nvim", manifest: "NEOVIM", version: values["NEOVIM_VERSION"], archiveKind: platformSpec.toolArchive, stripPrefix: platformSpec.neovimPrefix, expected: "bin/nvim" + platformSpec.executableExt},
		{name: "chezmoi", manifest: "CHEZMOI", version: values["CHEZMOI_VERSION"], archiveKind: platformSpec.toolArchive, expected: "chezmoi" + platformSpec.executableExt},
		{name: "ripgrep", manifest: "RIPGREP", version: values["RIPGREP_VERSION"], archiveKind: platformSpec.toolArchive, stripPrefix: "ripgrep-" + values["RIPGREP_VERSION"] + "-" + platformSpec.ripgrepSuffix, expected: "rg" + platformSpec.executableExt},
		{name: "fd", manifest: "FD", version: fdVersion, archiveKind: platformSpec.toolArchive, stripPrefix: "fd-v" + fdVersion + "-" + platformSpec.fdSuffix, expected: "fd" + platformSpec.executableExt},
		{name: "fzf", manifest: "FZF", version: values["FZF_VERSION"], archiveKind: platformSpec.toolArchive, destination: platformSpec.binaryPrefix, expected: path.Join(platformSpec.binaryPrefix, "fzf"+platformSpec.executableExt)},
		{name: "lazygit", manifest: "LAZYGIT", version: values["LAZYGIT_VERSION"], archiveKind: platformSpec.toolArchive, expected: "lazygit" + platformSpec.executableExt},
		{name: "tree-sitter", manifest: "TREE_SITTER", version: values["TREE_SITTER_VERSION"], archiveKind: ArchiveZip, destination: platformSpec.binaryPrefix, expected: path.Join(platformSpec.binaryPrefix, "tree-sitter"+platformSpec.executableExt)},
	}

	assetKeys := make([]string, 0, len(specs)*2)
	for _, spec := range specs {
		prefix := spec.manifest + "_" + platformSpec.manifestKey
		assetKeys = append(assetKeys, prefix+"_URL", prefix+"_SHA256")
	}
	fontPlatform := "UNIX"
	fontKind := ArchiveTarXz
	if platform.GOOS == "windows" {
		fontPlatform = "WINDOWS"
		fontKind = ArchiveZip
	}
	assetKeys = append(assetKeys, "NERD_FONT_"+fontPlatform+"_URL", "NERD_FONT_"+fontPlatform+"_SHA256")
	if err := values.Require(assetKeys...); err != nil {
		return Catalog{}, err
	}

	releases := make([]Release, 0, len(specs))
	for _, spec := range specs {
		manifestPrefix := spec.manifest + "_" + platformSpec.manifestKey
		release := Release{
			Name: spec.name, Version: spec.version, Platform: platform,
			URL: values[manifestPrefix+"_URL"], SHA256: values[manifestPrefix+"_SHA256"],
			ArchiveName: fmt.Sprintf("%s-%s-%s.%s", spec.name, spec.version, platform.ID, spec.archiveKind),
			ArchiveKind: spec.archiveKind, TargetName: spec.name + "-" + spec.version,
			StripPrefix: spec.stripPrefix, DestinationPrefix: spec.destination, ExpectedBinary: spec.expected,
		}
		if err := validatePinnedArtifact(release.URL, release.SHA256, release.Name); err != nil {
			return Catalog{}, err
		}
		releases = append(releases, release)
	}

	font := Font{
		Version:     values["NERD_FONT_VERSION"],
		URL:         values["NERD_FONT_"+fontPlatform+"_URL"],
		SHA256:      values["NERD_FONT_"+fontPlatform+"_SHA256"],
		ArchiveKind: fontKind,
	}
	font.ArchiveName = fmt.Sprintf("JetBrainsMono-%s.%s", font.Version, font.ArchiveKind)
	if err := validatePinnedArtifact(font.URL, font.SHA256, "font"); err != nil {
		return Catalog{}, err
	}
	return Catalog{Platform: platform, Tools: values, Releases: releases, Font: font}, nil
}

func validatePinnedArtifact(rawURL, checksum, name string) error {
	parsed, err := url.Parse(rawURL)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil {
		return fmt.Errorf("%s has an invalid HTTPS release URL", name)
	}
	digest, err := hex.DecodeString(checksum)
	if err != nil || len(digest) != 32 {
		return fmt.Errorf("%s has an invalid SHA-256 digest", name)
	}
	return nil
}

func (c Catalog) Release(name string) (Release, bool) {
	for _, release := range c.Releases {
		if release.Name == name {
			return release, true
		}
	}
	return Release{}, false
}
