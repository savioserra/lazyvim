//go:build !windows

package app

import (
	"errors"
	"syscall"
)

func isCrossDevice(err error) bool { return errors.Is(err, syscall.EXDEV) }
