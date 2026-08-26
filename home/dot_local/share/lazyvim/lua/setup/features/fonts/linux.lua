local commands = require("setup.commands")

local M = {}

function M.configure(context)
	commands.execute("fc-cache", { "-f", context.paths.join(context.paths.local_dir, "share", "fonts") })
end

function M.verify()
	local catalog = commands.capture("fc-list", { ":", "family" }):lower()
	assert(catalog:find("jetbrainsmono nerd font", 1, true), "fontconfig cannot see JetBrainsMono Nerd Font")
end

return M
