local M = {}

function M.create()
	local paths = require("lazyvim_capabilities.paths")
	vim.env.HOME = paths.home
	vim.env.USERPROFILE = paths.home
	vim.env.XDG_CONFIG_HOME = paths.join(paths.home, ".config")
	local platform = require("lazyvim_capabilities.platforms")
	platform.configure_runtime()
	return { paths = paths, platform = platform, versions = require("lazyvim_capabilities.versions") }
end

return M
