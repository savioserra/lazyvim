return {
	{
		id = "go",
		requires = { "go" },
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
	{
		id = "typescript",
		requires = { "node" },
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
	{
		id = "standard",
		lazyvim_extras = {
			"lazyvim.plugins.extras.lang.docker",
			"lazyvim.plugins.extras.lang.json",
			"lazyvim.plugins.extras.lang.markdown",
			"lazyvim.plugins.extras.lang.tailwind",
			"lazyvim.plugins.extras.lang.toml",
			"lazyvim.plugins.extras.lang.yaml",
		},
		language_cases = {
			{ language = "lua", filename = "attachment-test.lua", contents = "local answer = 42\n", client = "lua_ls" },
			{
				language = "html",
				filename = "attachment-test.html",
				contents = "<!doctype html><title>test</title>\n",
				client = "html",
			},
			{
				language = "css",
				filename = "attachment-test.css",
				contents = "body { color: red; }\n",
				client = "cssls",
			},
			{
				language = "json",
				filename = "attachment-test.json",
				contents = '{ "answer": 42 }\n',
				client = "jsonls",
			},
			{ language = "yaml", filename = "attachment-test.yaml", contents = "answer: 42\n", client = "yamlls" },
			{
				language = "markdown",
				filename = "attachment-test.md",
				contents = "# Behavior test\n",
				client = "marksman",
			},
			{ language = "dockerfile", filename = "Dockerfile", contents = "FROM scratch\n", client = "dockerls" },
		},
	},
}
