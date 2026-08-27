local commands = require("workstation.commands")

return function()
	return {
		id = "go",
		requires = { "foundation" },
		verify = function(context)
			local actual = commands.capture(context.platform.tool("go"), { "version" })
			assert(vim.startswith(actual, "go version go" .. context.versions.go), "Unexpected Go version: " .. actual)
		end,
	}
end
