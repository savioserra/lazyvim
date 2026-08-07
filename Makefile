GO ?= go
BINARY := .build/dotfiles
VERSION ?= $(shell git describe --always --dirty 2>/dev/null || printf dev)
RELEASE_BASE ?= https://github.com/savioserra/lazyvim/releases/latest/download
INSTALL_ARGS ?=
GO_SOURCES := $(shell find cmd internal -type f -name '*.go' -print) assets.go go.mod go.sum .chezmoiroot manifests/tools.env manifests/tmux-plugins.lock $(shell find home bundles -type f -print)

.PHONY: build test bootstrap install apply capture restore restore-tmux check update sync lock-mason downloads bundle-downloads clean

build: $(BINARY)

$(BINARY): $(GO_SOURCES)
	@mkdir -p $(dir $@)
	$(GO) build -trimpath -ldflags "-s -w -X github.com/savioserra/lazyvim/internal/buildinfo.version=$(VERSION)" -o $@ ./cmd/dotfiles

test:
	$(GO) test ./...
	$(GO) vet ./...

# Download a verified release binary and hand installation to the Go CLI.
# This target intentionally requires no local Go toolchain.
bootstrap:
	@set -eu; \
	platform=$$(uname -s); machine=$$(uname -m); \
	case "$$platform/$$machine" in \
		Darwin/arm64) architecture=arm64 ;; \
		Darwin/x86_64) architecture=amd64 ;; \
		Linux/x86_64) architecture=amd64 ;; \
		*) printf 'No published dotfiles binary supports %s/%s\n' "$$platform" "$$machine" >&2; exit 1 ;; \
	esac; \
	asset="dotfiles_$${platform}_$${architecture}.tar.gz"; \
	base="$(RELEASE_BASE)"; \
	temporary=$$(mktemp -d); \
	trap 'rm -rf "$$temporary"' 0 1 2 15; \
	printf 'Downloading %s\n' "$$asset"; \
	curl --fail --location --retry 3 --output "$$temporary/$$asset" "$$base/$$asset"; \
	curl --fail --location --retry 3 --output "$$temporary/SHA256SUMS" "$$base/SHA256SUMS"; \
	checksum=$$(grep "  $$asset$$" "$$temporary/SHA256SUMS") || { printf 'Release checksum is missing for %s\n' "$$asset" >&2; exit 1; }; \
	if command -v shasum >/dev/null 2>&1; then verifier='shasum -a 256'; else verifier=sha256sum; fi; \
	(cd "$$temporary" && printf '%s\n' "$$checksum" | $$verifier -c -); \
	tar -C "$$temporary" -xzf "$$temporary/$$asset"; \
	"$$temporary/dotfiles" --repo "$(CURDIR)" install $(INSTALL_ARGS)

install: $(BINARY)
	$(BINARY) install

apply: $(BINARY)
	$(BINARY) apply

capture: $(BINARY)
	$(BINARY) capture

restore: $(BINARY)
	$(BINARY) restore

restore-tmux: $(BINARY)
	$(BINARY) restore-tmux

check: $(BINARY)
	$(BINARY) check

update: $(BINARY)
	$(BINARY) update

sync: $(BINARY)
	$(BINARY) sync

lock-mason: $(BINARY)
	$(BINARY) lock-mason

downloads: $(BINARY)
	$(BINARY) downloads list --font

bundle-downloads: $(BINARY)
	$(BINARY) downloads bundle --all-platforms --font

clean:
	rm -rf .build
