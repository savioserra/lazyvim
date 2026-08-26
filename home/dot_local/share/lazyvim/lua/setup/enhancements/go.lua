local commands = require("setup.commands")
local define = require("setup.contract")
return define({
	id = "language.go",
	requires = { "nvim" },
	enhancements = {
		nvim = {
			{
				extras_module = "languages.extras.go",
				lazyvim_extras = { "lazyvim.plugins.extras.lang.go" },
				language_cases = {
					{
						language = "go",
						filename = "attachment_test.go",
						contents = "package behavior\n\nvar answer = 42\n",
						client = "gopls",
					},
				},
			},
		},
	},
	verify = function(context)
		local actual = commands.capture(context.platform.tool("go"), { "version" })
		assert(vim.startswith(actual, "go version go" .. context.versions.go), "Unexpected Go version: " .. actual)
	end,
})
