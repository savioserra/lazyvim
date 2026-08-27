local M = {}

---@class RuntimeContext
---@field paths table
---@field platform table
---@field versions table

---@return RuntimeContext
function M.create()
	local paths = require("workstation.paths")
	vim.env.HOME = paths.home
	vim.env.USERPROFILE = paths.home
	vim.env.XDG_CONFIG_HOME = paths.join(paths.home, ".config")
	local platform = require("workstation.platforms")
	platform.configure_runtime()
	return { paths = paths, platform = platform, versions = require("workstation.versions") }
end

return M
