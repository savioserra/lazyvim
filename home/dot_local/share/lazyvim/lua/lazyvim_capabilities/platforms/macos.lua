local commands = require("lazyvim_capabilities.commands")
local paths = require("lazyvim_capabilities.paths")
local M = require("lazyvim_capabilities.platforms.unix")

M.name = "darwin"
function M.configure_fonts() end

function M.verify_fonts()
	local directory = paths.join(paths.home, "Library", "Fonts", "JetBrainsMonoNerdFont")
	local found = false
	for name in vim.fs.dir(directory) do
		if name:sub(-4) == ".ttf" then
			found = true
			break
		end
	end
	assert(found, "No JetBrainsMono Nerd Font files installed")
	local catalog = commands.capture("system_profiler", { "SPFontsDataType", "-json" }):lower()
	assert(catalog:find("jetbrainsmono", 1, true), "macOS font catalog cannot see JetBrainsMono Nerd Font")
end

return M
