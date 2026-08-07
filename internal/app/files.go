package app

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/savioserra/lazyvim/internal/atomicfile"
)

func (a *App) backup(path string) error {
	_, err := a.backupWithDestination(path)
	return err
}

func (a *App) backupWithDestination(path string) (string, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	relative, err := filepath.Rel(a.paths.Home, absolute)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		volume := filepath.VolumeName(absolute)
		relative = strings.TrimPrefix(absolute, volume)
		relative = strings.TrimLeft(relative, `/\\`)
		if volume != "" {
			relative = strings.TrimSuffix(strings.ReplaceAll(volume, ":", ""), string(filepath.Separator)) + string(filepath.Separator) + relative
		}
	}
	destination := filepath.Join(a.backupDirectory(), relative)
	if pathExists(destination) {
		return "", fmt.Errorf("backup destination already exists: %s", destination)
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return "", err
	}
	if err := movePath(path, destination); err != nil {
		return "", fmt.Errorf("back up %s: %w", path, err)
	}
	a.logf("Backed up %s to %s", path, destination)
	return destination, nil
}

func (a *App) link(source, target string) error {
	source, err := filepath.Abs(source)
	if err != nil {
		return err
	}
	if pathExists(target) {
		resolved, resolveErr := filepath.EvalSymlinks(target)
		if resolveErr == nil {
			resolved, _ = filepath.Abs(resolved)
			if samePath(resolved, source) {
				a.logf("Already linked: %s", target)
				return nil
			}
		}
		if err := a.backup(target); err != nil {
			return err
		}
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	if err := os.Symlink(source, target); err != nil {
		return fmt.Errorf("link %s to %s: %w", target, source, err)
	}
	a.logf("Linked %s -> %s", target, source)
	return nil
}

func (a *App) connectDirectory(source, target string) error {
	source, err := filepath.Abs(source)
	if err != nil {
		return err
	}
	if pathExists(target) {
		resolved, resolveErr := filepath.EvalSymlinks(target)
		if resolveErr == nil && samePath(resolved, source) {
			a.logf("Already linked: %s", target)
			return nil
		}
		if err := a.backup(target); err != nil {
			return err
		}
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	if runtime.GOOS == "windows" {
		command := exec.Command("cmd.exe", "/d", "/v:off", "/s", "/c", `mklink /J "%LAZYVIM_JUNCTION_TARGET%" "%LAZYVIM_JUNCTION_SOURCE%"`)
		command.Env = append(os.Environ(), "LAZYVIM_JUNCTION_TARGET="+target, "LAZYVIM_JUNCTION_SOURCE="+source)
		if output, err := command.CombinedOutput(); err == nil {
			a.logf("Linked %s -> %s", target, source)
			return nil
		} else {
			_ = os.Remove(target)
			if symbolicErr := os.Symlink(source, target); symbolicErr != nil {
				return fmt.Errorf("could not link %s to %s (junction: %v: %s; symlink: %w); enable Windows Developer Mode or use compatible local volumes", target, source, err, strings.TrimSpace(string(output)), symbolicErr)
			}
		}
	} else if err := os.Symlink(source, target); err != nil {
		return fmt.Errorf("link %s to %s: %w", target, source, err)
	}
	a.logf("Linked %s -> %s", target, source)
	return nil
}

func samePath(left, right string) bool {
	left = filepath.Clean(left)
	right = filepath.Clean(right)
	if runtime.GOOS == "windows" {
		return strings.EqualFold(left, right)
	}
	return left == right
}

func copyFile(source, destination string, mode os.FileMode) error {
	return copyFileWithReplace(source, destination, mode, atomicfile.Replace)
}

func copyFileWithReplace(source, destination string, mode os.FileMode, replace func(string, string) error) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return err
	}
	output, err := os.CreateTemp(filepath.Dir(destination), "."+filepath.Base(destination)+".tmp-*")
	if err != nil {
		return err
	}
	temporary := output.Name()
	defer os.Remove(temporary)
	if err := output.Chmod(mode); err != nil {
		_ = output.Close()
		return err
	}
	_, copyErr := io.Copy(output, input)
	var syncErr error
	if copyErr == nil {
		syncErr = output.Sync()
	}
	closeErr := output.Close()
	if copyErr != nil {
		return copyErr
	}
	if syncErr != nil {
		return syncErr
	}
	if closeErr != nil {
		return closeErr
	}
	if err := replace(temporary, destination); err != nil {
		return err
	}
	return nil
}

func movePath(source, destination string) error {
	if err := os.Rename(source, destination); err == nil {
		return nil
	} else if !isCrossDevice(err) {
		return err
	}
	info, err := os.Lstat(source)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		target, err := os.Readlink(source)
		if err != nil {
			return err
		}
		if err := os.Symlink(target, destination); err != nil {
			return err
		}
		return os.Remove(source)
	}
	if !info.IsDir() {
		if err := copyFile(source, destination, info.Mode().Perm()); err != nil {
			return err
		}
		return os.Remove(source)
	}
	return moveDirectory(source, destination)
}

func moveDirectory(source, destination string) error {
	if err := os.Rename(source, destination); err == nil {
		return nil
	} else if !isCrossDevice(err) {
		return err
	}
	if err := filepath.WalkDir(source, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		relative, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		target := filepath.Join(destination, relative)
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return os.MkdirAll(target, info.Mode().Perm())
		}
		if info.Mode()&os.ModeSymlink != 0 {
			link, err := os.Readlink(path)
			if err != nil {
				return err
			}
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			return os.Symlink(link, target)
		}
		return copyFile(path, target, info.Mode().Perm())
	}); err != nil {
		_ = os.RemoveAll(destination)
		return err
	}
	return os.RemoveAll(source)
}

func fileSHA(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func (a *App) installSelf() (string, error) {
	executable, err := a.executablePath()
	if err != nil {
		return "", fmt.Errorf("locate lazyvim executable: %w", err)
	}
	executable, err = filepath.EvalSymlinks(executable)
	if err != nil {
		return "", fmt.Errorf("resolve lazyvim executable: %w", err)
	}
	source, err := os.Open(executable)
	if err != nil {
		return "", fmt.Errorf("open lazyvim executable: %w", err)
	}
	defer source.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, source); err != nil {
		return "", fmt.Errorf("hash lazyvim executable: %w", err)
	}
	digest := hex.EncodeToString(hash.Sum(nil))
	if _, err := source.Seek(0, io.SeekStart); err != nil {
		return "", err
	}
	target := filepath.Join(a.paths.Opt, "lazyvim-"+digest, "lazyvim"+runtimeExecutableExtension())
	if info, err := os.Lstat(target); err == nil {
		actual, hashErr := fileSHA(target)
		if info.Mode().IsRegular() && executableFile(target) && hashErr == nil && actual == digest {
			return target, nil
		}
		if _, err := a.backupWithDestination(target); err != nil {
			return "", err
		}
	} else if !os.IsNotExist(err) {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return "", err
	}
	output, err := os.CreateTemp(filepath.Dir(target), ".lazyvim.tmp-*")
	if err != nil {
		return "", err
	}
	temporary := output.Name()
	defer os.Remove(temporary)
	if err := output.Chmod(0o755); err != nil {
		_ = output.Close()
		return "", err
	}
	_, copyErr := io.Copy(output, source)
	var syncErr error
	if copyErr == nil {
		syncErr = output.Sync()
	}
	closeErr := output.Close()
	if copyErr != nil {
		return "", copyErr
	}
	if syncErr != nil {
		return "", syncErr
	}
	if closeErr != nil {
		return "", closeErr
	}
	if err := os.Rename(temporary, target); err != nil {
		return "", fmt.Errorf("publish lazyvim executable: %w", err)
	}
	a.logf("Installed lazyvim CLI %s", digest[:12])
	return target, nil
}

func (a *App) writeCommandShim(name, executable string, arguments ...string) error {
	if runtime.GOOS != "windows" {
		return a.link(executable, filepath.Join(a.paths.Bin, name))
	}
	if err := os.MkdirAll(a.paths.Bin, 0o755); err != nil {
		return err
	}
	shim := filepath.Join(a.paths.Bin, name+".cmd")
	quotedArguments := make([]string, 0, len(arguments))
	for _, argument := range arguments {
		quotedArguments = append(quotedArguments, quoteCMD(argument))
	}
	content := "@echo off\r\nsetlocal DisableDelayedExpansion\r\n\"" + escapeBatchLiteral(executable) + "\""
	if len(quotedArguments) > 0 {
		content += " " + strings.Join(quotedArguments, " ")
	}
	content += " %*\r\n"
	if existing, err := os.ReadFile(shim); err == nil && string(existing) == content {
		a.logf("Already installed shim: %s", shim)
		return nil
	}
	if err := os.WriteFile(shim, []byte(content), 0o644); err != nil {
		return err
	}
	a.logf("Installed shim: %s", shim)
	return nil
}

func quoteCMD(value string) string {
	return "\"" + escapeBatchLiteral(value) + "\""
}

func escapeBatchLiteral(value string) string {
	value = strings.ReplaceAll(value, "%", "%%")
	return strings.ReplaceAll(value, "\"", "\"\"")
}
