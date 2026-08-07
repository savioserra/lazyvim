//go:build windows

package app

import (
	"errors"

	"golang.org/x/sys/windows"
)

func isCrossDevice(err error) bool { return errors.Is(err, windows.ERROR_NOT_SAME_DEVICE) }
