local commands = require("setup.commands")
local paths = require("setup.paths")
return require("setup.platforms.unix").new({
	name = "darwin",
	configure_fonts = function() end,
	verify_fonts = function()
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
	end,
})
