local commands = require("workstation.commands")

local M = {}

function M.directory(context)
	return context.paths.join(context.paths.home, "Library", "Fonts", "JetBrainsMonoNerdFont")
end

function M.configure() end

function M.verify(context)
	local directory = M.directory(context)
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
