-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

vim.keymap.set("n", "<C-s>", "<cmd>write<cr>", { desc = "Save file" })
vim.keymap.set("i", "<C-s>", function()
  vim.cmd("write")
end, { desc = "Save file" })
vim.keymap.set("n", "gl", ":", { desc = "Go to line" })
