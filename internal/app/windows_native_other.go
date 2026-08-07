//go:build !windows

package app

func (a *App) addUserPath(string) error { return nil }

func notifyWindowsFontChange() error { return nil }
