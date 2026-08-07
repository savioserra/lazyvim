package lazyvim

import "embed"

// Embedded contains the complete chezmoi source state, pinned manifests, and
// optional release archives. Put checksummed archives in bundles/ before
// building to produce a network-independent host-tool installer.
//
//go:embed .chezmoiroot all:home all:manifests all:bundles
var Embedded embed.FS
