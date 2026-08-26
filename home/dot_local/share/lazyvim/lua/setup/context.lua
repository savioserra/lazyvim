local M = {}

---@class RuntimeContext
---@field paths table
---@field platform table
---@field versions table

---@return RuntimeContext
function M.create()
	local paths = require("setup.paths")
	vim.env.HOME = paths.home
	vim.env.USERPROFILE = paths.home
	vim.env.XDG_CONFIG_HOME = paths.join(paths.home, ".config")
	local platform = require("setup.platforms")
	platform.configure_runtime()
	return { paths = paths, platform = platform, versions = require("setup.versions") }
end

return M
