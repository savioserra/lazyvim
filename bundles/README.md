# Optional embedded downloads

`lazyvim downloads bundle` writes pinned release archives here. Any archive
present when `go build` runs is included in the binary with `go:embed`; the
installer verifies its committed SHA-256 before use and falls back to the
network when an archive is not bundled.

Archives are ignored by Git by default because a complete platform matrix is
large. Build immediately after bundling to create an offline installer, or
explicitly force-add selected archives when publishing a self-contained source
release.
