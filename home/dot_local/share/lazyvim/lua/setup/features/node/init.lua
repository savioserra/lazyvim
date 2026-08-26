local commands = require("setup.commands")

local function backend(context)
	local module = context.platform.name == "win32" and "windows" or "unix"
	return require("setup.features.node." .. module)
end

return {
	setup = function(context)
		backend(context).configure(context)
	end,
	verify = function(context)
		backend(context).verify(context)
		local actual = commands.capture("node", { "--version" })
		assert(
			actual == "v" .. context.versions.node,
			("Expected managed Node v%s, got %s"):format(context.versions.node, actual)
		)
	end,
}
