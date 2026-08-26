local define = require("setup.contract")
return define({
	id = "language.typescript",
	requires = { "language.node", "nvim" },
	enhancements = {
		nvim = {
			{
				extras_module = "languages.extras.typescript",
				plugin_module = "languages.plugins.typescript",
				lazyvim_extras = {
					"lazyvim.plugins.extras.lang.typescript",
					"lazyvim.plugins.extras.linting.eslint",
					"lazyvim.plugins.extras.formatting.prettier",
				},
				mason_packages = { "typescript-language-server", "eslint-lsp", "prettier" },
				language_cases = {
					{
						language = "javascript",
						filename = "attachment-test.js",
						contents = "const answer = 42;\n",
						client = "typescript-tools",
					},
				},
				formatter_cases = {
					{
						language = "javascript",
						filename = "format-test.js",
						contents = "const answer=42\n",
						expected = "const answer = 42;\n",
						project_files = { [".prettierrc.json"] = "{}\n" },
					},
				},
			},
		},
	},
})
