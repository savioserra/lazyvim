package atomicfile

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// Write stages, syncs, and atomically publishes content at destination.
// The destination remains unchanged if staging or publication fails.
func Write(destination string, content []byte, mode os.FileMode) error {
	return write(destination, content, mode, Replace)
}

func write(destination string, content []byte, mode os.FileMode, publish func(string, string) error) (result error) {
	directory := filepath.Dir(destination)
	temporary, err := os.CreateTemp(directory, "."+filepath.Base(destination)+".tmp-*")
	if err != nil {
		return fmt.Errorf("create staged file: %w", err)
	}
	temporaryPath := temporary.Name()
	closed := false
	defer func() {
		if !closed {
			if err := temporary.Close(); err != nil && result == nil {
				result = fmt.Errorf("close staged file: %w", err)
			}
		}
		if err := os.Remove(temporaryPath); err != nil && !errors.Is(err, os.ErrNotExist) && result == nil {
			result = fmt.Errorf("remove staged file: %w", err)
		}
	}()
	if err := temporary.Chmod(mode); err != nil {
		return fmt.Errorf("set staged file mode: %w", err)
	}
	if _, err := temporary.Write(content); err != nil {
		return fmt.Errorf("write staged file: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		return fmt.Errorf("sync staged file: %w", err)
	}
	closeErr := temporary.Close()
	closed = true
	if closeErr != nil {
		return fmt.Errorf("close staged file: %w", closeErr)
	}
	if err := publish(temporaryPath, destination); err != nil {
		return fmt.Errorf("publish staged file: %w", err)
	}
	return nil
}
