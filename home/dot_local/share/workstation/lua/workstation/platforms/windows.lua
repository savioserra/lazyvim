local paths = require("workstation.paths")

local M = { name = "win32" }
local nvm_dir = paths.join(paths.local_dir, "opt", "nvm-windows")
local active_node_dir = paths.join(nvm_dir, "nodejs")
M.nvim = paths.join(paths.local_dir, "opt", "nvim", "bin", "nvim.exe")

function M.nvim_data()
	if vim.env.XDG_DATA_HOME and vim.env.XDG_DATA_HOME ~= "" then
		return paths.join(vim.env.XDG_DATA_HOME, "nvim")
	end
	return paths.join(vim.env.LOCALAPPDATA or paths.join(paths.home, "AppData", "Local"), "nvim-data")
end

function M.tool(name)
	if name == "go" then
		return paths.join(paths.local_dir, "opt", "go", "bin", "go.exe")
	end
	return paths.join(paths.local_dir, "bin", name .. ".exe")
end

function M.configure_runtime()
	vim.env.NVM_HOME = nvm_dir
	vim.env.NVM_SYMLINK = active_node_dir
	vim.env.PATH = table.concat({
		paths.join(paths.local_dir, "bin"),
		vim.fs.dirname(M.nvim),
		vim.fs.dirname(M.tool("go")),
		nvm_dir,
		active_node_dir,
		vim.env.PATH or "",
	}, ";")
end

return M
