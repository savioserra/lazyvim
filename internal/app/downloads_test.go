package app

import (
	"testing"

	"github.com/savioserra/lazyvim/internal/download"
)

func TestDownloadFontFlagPreservesNamedToolAndFont(t *testing.T) {
	items := []downloadable{
		{Name: "nvim", Artifact: download.Artifact{FileName: "nvim.zip"}},
		{Name: "font", Artifact: download.Artifact{FileName: "font.zip"}},
	}
	names := []string{"nvim"}
	if !downloadNamePresent(names, "font") {
		names = append(names, "font")
	}
	filtered, err := filterDownloads(items, names)
	if err != nil {
		t.Fatal(err)
	}
	if len(filtered) != 2 {
		t.Fatalf("got %d downloads, want tool and font", len(filtered))
	}
}
