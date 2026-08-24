local paths = require("lazyvim_capabilities.paths")
local versions = require("lazyvim_capabilities.versions")

local M = {}
M.node = paths.join(paths.local_dir, "opt", "nvm", "versions", "node", "v" .. versions.node, "bin", "node")
M.nvim = paths.join(paths.local_dir, "bin", "nvim")
M.nvim_data = paths.join(paths.local_dir, "share", "nvim")

function M.tool(name)
	return paths.join(paths.local_dir, "bin", name)
end

function M.configure_runtime()
	vim.env.PATH = table.concat({ vim.fs.dirname(M.node), paths.join(paths.local_dir, "bin"), vim.env.PATH or "" }, ":")
	vim.env.XDG_DATA_HOME = vim.env.XDG_DATA_HOME or paths.join(paths.local_dir, "share")
	vim.env.XDG_STATE_HOME = vim.env.XDG_STATE_HOME or paths.join(paths.local_dir, "state")
	vim.env.XDG_CACHE_HOME = vim.env.XDG_CACHE_HOME or paths.join(paths.home, ".cache")
end

function M.configure_node()
	paths.write(paths.join(paths.local_dir, "opt", "nvm", "alias", "default"), versions.node .. "\n")
end

function M.verify_node()
	local actual = vim.trim(paths.read(paths.join(paths.local_dir, "opt", "nvm", "alias", "default")))
	assert(actual == versions.node, ("expected nvm default %s, got %s"):format(versions.node, actual))
end

return M
