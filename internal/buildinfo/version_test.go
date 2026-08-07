package buildinfo

import "testing"

func TestResolveVersion(t *testing.T) {
	tests := []struct {
		name     string
		injected string
		revision string
		modified bool
		expected string
	}{
		{name: "injected", injected: "v1.2.3", revision: "abcdef", expected: "v1.2.3"},
		{name: "revision", revision: "1234567890abcdef", expected: "1234567890ab"},
		{name: "dirty revision", revision: "1234567890abcdef", modified: true, expected: "1234567890ab-dirty"},
		{name: "development", expected: "dev"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := resolveVersion(test.injected, test.revision, test.modified); got != test.expected {
				t.Fatalf("got %q, want %q", got, test.expected)
			}
		})
	}
	if Variable() != "github.com/savioserra/lazyvim/internal/buildinfo.version" {
		t.Fatalf("unexpected linker variable: %s", Variable())
	}
}
