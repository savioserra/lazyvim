local commands = require("setup.commands")
local paths = require("setup.paths")
return require("setup.platforms.unix").new({
	name = "linux",
	configure_fonts = function()
		commands.execute("fc-cache", { "-f", paths.join(paths.local_dir, "share", "fonts") })
	end,
	verify_fonts = function()
		local catalog = commands.capture("fc-list", { ":", "family" }):lower()
		assert(catalog:find("jetbrainsmono nerd font", 1, true), "fontconfig cannot see JetBrainsMono Nerd Font")
	end,
})
