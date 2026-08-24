local commands = require("lazyvim_capabilities.commands")
local paths = require("lazyvim_capabilities.paths")
local M = require("lazyvim_capabilities.platforms.unix")

M.name = "linux"

function M.configure_fonts()
	commands.try_execute("fc-cache", { "-f", paths.join(paths.local_dir, "share", "fonts") })
end

function M.verify_fonts()
	local catalog = commands.capture("fc-list", { ":", "family" }):lower()
	assert(catalog:find("jetbrainsmono nerd font", 1, true), "fontconfig cannot see JetBrainsMono Nerd Font")
end

return M
