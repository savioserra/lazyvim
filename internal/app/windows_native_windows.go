//go:build windows

package app

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const (
	windowBroadcast        = 0xffff
	messageFontChange      = 0x001d
	messageSettingChange   = 0x001a
	sendMessageAbortIfHung = 0x0002
)

var sendMessageTimeout = windows.NewLazySystemDLL("user32.dll").NewProc("SendMessageTimeoutW")

func (a *App) addUserPath(directory string) error {
	key, err := registry.OpenKey(registry.CURRENT_USER, `Environment`, registry.QUERY_VALUE|registry.SET_VALUE)
	if err != nil {
		return fmt.Errorf("open user environment registry key: %w", err)
	}
	defer key.Close()

	current, valueType, err := key.GetStringValue("Path")
	if err != nil && !errors.Is(err, registry.ErrNotExist) {
		return fmt.Errorf("read user PATH: %w", err)
	}
	if errors.Is(err, registry.ErrNotExist) {
		current = ""
		valueType = registry.EXPAND_SZ
	}
	for _, entry := range splitWindowsPath(current) {
		if strings.EqualFold(strings.TrimRight(entry, `\`), strings.TrimRight(directory, `\`)) {
			return ensureProcessPath(directory)
		}
	}
	updated := directory
	if current != "" {
		updated += ";" + current
	}
	switch valueType {
	case registry.SZ:
		err = key.SetStringValue("Path", updated)
	default:
		err = key.SetExpandStringValue("Path", updated)
	}
	if err != nil {
		return fmt.Errorf("write user PATH: %w", err)
	}
	if err := broadcastWindowsMessage(messageSettingChange, "Environment"); err != nil {
		a.warnf("could not broadcast the PATH update: %v", err)
	}
	a.logf("Added %s to the user PATH", directory)
	return ensureProcessPath(directory)
}

func ensureProcessPath(directory string) error {
	for _, entry := range splitWindowsPath(os.Getenv("PATH")) {
		if strings.EqualFold(strings.TrimRight(entry, `\`), strings.TrimRight(directory, `\`)) {
			return nil
		}
	}
	return os.Setenv("PATH", directory+";"+os.Getenv("PATH"))
}

func splitWindowsPath(value string) []string {
	var entries []string
	for _, entry := range strings.Split(value, ";") {
		if strings.TrimSpace(entry) != "" {
			entries = append(entries, entry)
		}
	}
	return entries
}

func notifyWindowsFontChange() error {
	return broadcastWindowsMessage(messageFontChange, "")
}

func broadcastWindowsMessage(message uintptr, text string) error {
	var textPointer *uint16
	var err error
	if text != "" {
		textPointer, err = windows.UTF16PtrFromString(text)
		if err != nil {
			return err
		}
	}
	var result uintptr
	returnValue, _, callErr := sendMessageTimeout.Call(
		windowBroadcast,
		message,
		0,
		uintptr(unsafe.Pointer(textPointer)),
		sendMessageAbortIfHung,
		5000,
		uintptr(unsafe.Pointer(&result)),
	)
	if returnValue == 0 {
		if callErr != windows.ERROR_SUCCESS {
			return callErr
		}
		return fmt.Errorf("SendMessageTimeoutW returned no result")
	}
	return nil
}
