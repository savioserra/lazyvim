local commands = require("lazyvim_capabilities.commands")
local define = require("lazyvim_capabilities.contract")
return define({
	id = "language.node",
	requires = { "foundation" },
	setup = function(context)
		context.platform.configure_node()
	end,
	verify = function(context)
		context.platform.verify_node()
		local actual = commands.capture("node", { "--version" })
		assert(
			actual == "v" .. context.versions.node,
			("Expected managed Node v%s, got %s"):format(context.versions.node, actual)
		)
	end,
})
