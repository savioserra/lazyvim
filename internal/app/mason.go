package app

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/savioserra/lazyvim/internal/atomicfile"
)

func (a *App) LockMason(ctx context.Context) error {
	if err := a.requireActualRepository("lock-mason"); err != nil {
		return err
	}
	packagesHome := filepath.Join(a.paths.NvimData, "mason", "packages")
	if !directory(packagesHome) {
		return fmt.Errorf("Mason package directory does not exist: %s", packagesHome)
	}
	entries, err := os.ReadDir(packagesHome)
	if err != nil {
		return err
	}
	packages := map[string]string{}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		receiptPath := filepath.Join(packagesHome, entry.Name(), "mason-receipt.json")
		if !regularFile(receiptPath) {
			continue
		}
		receipt, err := readMasonReceipt(receiptPath)
		if err != nil {
			return err
		}
		if receipt.Name == "" {
			return fmt.Errorf("invalid Mason receipt: %s", receiptPath)
		}
		version, err := masonReceiptVersion(receipt, receiptPath)
		if err != nil {
			return err
		}
		packages[receipt.Name] = version
	}
	if len(packages) == 0 {
		return fmt.Errorf("no installed Mason packages found")
	}
	content, err := json.MarshalIndent(packages, "", "  ")
	if err != nil {
		return err
	}
	content = append(content, '\n')
	active := filepath.Join(a.paths.Home, ".config", "nvim", "mason-lock.json")
	if !directory(filepath.Dir(active)) {
		return fmt.Errorf("managed Neovim configuration is missing; run lazyvim apply first")
	}
	if err := atomicfile.Write(active, content, 0o644); err != nil {
		return err
	}
	if err := a.Capture(ctx, []string{active}); err != nil {
		return err
	}
	a.logf("Locked %d Mason packages in home/dot_config/nvim/mason-lock.json", len(packages))
	return nil
}
