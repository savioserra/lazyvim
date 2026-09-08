local commands = require("workstation.commands")

return function()
	return {
		id = "secrets",
		requires = { "foundation" },
		verify = function(context)
			local actual = commands.capture(context.platform.tool("op"), { "--version" })
			assert(
				actual == context.versions.onepassword_cli,
				("Expected 1Password CLI %s, got %s"):format(context.versions.onepassword_cli, actual)
			)
		end,
	}
end
