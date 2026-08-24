local paths = require("lazyvim_capabilities.paths")

return {
	fd_major = "10",
	fzf = "0.74.2",
	go = "1.27.0",
	lazygit = "0.63.1",
	neovim = "0.12.4",
	node = vim.trim(paths.read(paths.join(paths.home, ".node-version"))),
	nvm_windows = "1.2.2",
	ripgrep = "15.2.0",
	tree_sitter = "0.26.11",
}
