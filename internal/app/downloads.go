package app

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/savioserra/lazyvim/internal/config"
	"github.com/savioserra/lazyvim/internal/download"
)

type DownloadOptions struct {
	Names        []string
	AllPlatforms bool
	IncludeFont  bool
	Bundle       bool
}

type downloadable struct {
	Name     string
	Platform string
	Artifact download.Artifact
}

func (a *App) FetchDownloads(ctx context.Context, options DownloadOptions) error {
	items, err := a.downloadables(options.AllPlatforms, options.IncludeFont)
	if err != nil {
		return err
	}
	names := append([]string(nil), options.Names...)
	if options.IncludeFont && len(names) > 0 && !downloadNamePresent(names, "font") {
		names = append(names, "font")
	}
	items, err = filterDownloads(items, names)
	if err != nil {
		return err
	}
	destination := a.paths.DownloadCache
	if options.Bundle {
		if err := a.requireActualRepository("downloads bundle"); err != nil {
			return err
		}
		destination = filepath.Join(a.repoRoot, "bundles")
	}
	seen := map[string]bool{}
	for _, item := range items {
		key := item.Artifact.FileName + ":" + item.Artifact.SHA256
		if seen[key] {
			continue
		}
		seen[key] = true
		if _, err := a.downloader.Fetch(ctx, item.Artifact, destination); err != nil {
			return err
		}
	}
	a.logf("Fetched %d pinned archive(s) into %s", len(seen), destination)
	if options.Bundle {
		fmt.Fprintln(a.out, "Rebuild the CLI now to include these archives with go:embed.")
	}
	return nil
}

func (a *App) VerifyDownloads(allPlatforms, includeFont bool) error {
	items, err := a.downloadables(allPlatforms, includeFont)
	if err != nil {
		return err
	}
	seen := map[string]bool{}
	for _, item := range items {
		key := item.Artifact.FileName + ":" + item.Artifact.SHA256
		if seen[key] {
			continue
		}
		seen[key] = true
		cached := filepath.Join(a.paths.DownloadCache, item.Artifact.FileName)
		matches, err := download.ChecksumMatches(cached, item.Artifact.SHA256)
		if err != nil {
			return err
		}
		if !matches {
			return fmt.Errorf("missing or invalid cached archive: %s", cached)
		}
	}
	a.logf("Verified %d cached archive(s)", len(seen))
	return nil
}

func (a *App) ListDownloads(allPlatforms, includeFont bool) error {
	items, err := a.downloadables(allPlatforms, includeFont)
	if err != nil {
		return err
	}
	seen := map[string]bool{}
	for _, item := range items {
		key := item.Artifact.FileName + ":" + item.Artifact.SHA256
		if seen[key] {
			continue
		}
		seen[key] = true
		status := "remote"
		if _, err := fs.Stat(a.embedded, "bundles/"+item.Artifact.FileName); err == nil {
			status = "bundled"
		} else if matches, _ := download.ChecksumMatches(filepath.Join(a.paths.DownloadCache, item.Artifact.FileName), item.Artifact.SHA256); matches {
			status = "cached"
		}
		fmt.Fprintf(a.out, "%-14s %-18s %-8s %s\n", item.Name, item.Platform, status, item.Artifact.FileName)
	}
	return nil
}

func (a *App) CleanDownloads() error {
	if err := os.RemoveAll(a.paths.DownloadCache); err != nil {
		return err
	}
	if err := os.MkdirAll(a.paths.DownloadCache, 0o755); err != nil {
		return err
	}
	a.logf("Cleaned download cache: %s", a.paths.DownloadCache)
	return nil
}

func (a *App) downloadables(allPlatforms, includeFont bool) ([]downloadable, error) {
	platforms := []config.Platform{a.platform}
	if allPlatforms {
		platforms = config.SupportedPlatforms()
	}
	var items []downloadable
	for _, platform := range platforms {
		catalog, err := config.NewCatalog(a.tools, platform)
		if err != nil {
			return nil, err
		}
		for _, release := range catalog.Releases {
			items = append(items, downloadable{Name: release.Name, Platform: platform.ID, Artifact: download.Artifact{URL: release.URL, SHA256: release.SHA256, FileName: release.ArchiveName}})
		}
		if includeFont {
			items = append(items, downloadable{Name: "font", Platform: platform.ID, Artifact: download.Artifact{URL: catalog.Font.URL, SHA256: catalog.Font.SHA256, FileName: catalog.Font.ArchiveName}})
		}
	}
	sort.Slice(items, func(left, right int) bool {
		if items[left].Platform == items[right].Platform {
			return items[left].Name < items[right].Name
		}
		return items[left].Platform < items[right].Platform
	})
	return items, nil
}

func downloadNamePresent(names []string, expected string) bool {
	for _, name := range names {
		if strings.EqualFold(name, expected) {
			return true
		}
	}
	return false
}

func filterDownloads(items []downloadable, names []string) ([]downloadable, error) {
	if len(names) == 0 {
		return items, nil
	}
	requested := map[string]bool{}
	for _, name := range names {
		requested[strings.ToLower(name)] = true
	}
	var filtered []downloadable
	available := map[string]bool{}
	for _, item := range items {
		available[item.Name] = true
		if requested[item.Name] {
			filtered = append(filtered, item)
		}
	}
	var unknown []string
	for name := range requested {
		if !available[name] {
			unknown = append(unknown, name)
		}
	}
	if len(unknown) > 0 {
		sort.Strings(unknown)
		return nil, fmt.Errorf("unknown download name(s): %s", strings.Join(unknown, ", "))
	}
	return filtered, nil
}
