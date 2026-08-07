//go:build windows

package atomicfile

import "golang.org/x/sys/windows"

// Replace atomically publishes source at destination, replacing destination if it exists.
// Both paths must be on the same volume.
func Replace(source, destination string) error {
	from, err := windows.UTF16PtrFromString(source)
	if err != nil {
		return err
	}
	to, err := windows.UTF16PtrFromString(destination)
	if err != nil {
		return err
	}
	return windows.MoveFileEx(from, to, windows.MOVEFILE_REPLACE_EXISTING|windows.MOVEFILE_WRITE_THROUGH)
}
