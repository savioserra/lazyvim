//go:build !windows

package atomicfile

import "os"

// Replace atomically publishes source at destination, replacing destination if it exists.
// Both paths must be on the same filesystem.
func Replace(source, destination string) error {
	return os.Rename(source, destination)
}
