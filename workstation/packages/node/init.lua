local commands = require("workstation.commands")

local function backend(context)
	return require("packages.node.unix")
end

return function()
	return {
		id = "node",
		requires = { "foundation" },
		setup = function(context)
			backend(context).provision(context)
			backend(context).configure(context)
			context.platform.configure_runtime()
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
end
