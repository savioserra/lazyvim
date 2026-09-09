local leaf = require("packages.nvim.leaf")
local profile_module = require("packages.nvim.profile")
local provision = require("workstation.provision.recipes")

-- The typescript capability: an explicitly registered language package that
-- requires the Node runtime and the nvim editor, owns its deployed plugin
-- module and its profile intent, and verifies its own behavior through the
-- nvim-owned leaf helpers.

local intent = {
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
}

return function()
	return {
		id = "typescript",
		requires = { "node", "nvim" },
		contributes = {
			profile_module.recipe({ order = 20, entry = intent }),
			provision.chezmoi({
				target = ".config/nvim/lua/languages/plugins/typescript.lua",
				kind = "file",
				asset = "files/languages/plugins/typescript.lua",
			}),
		},
		verify = function(context)
			assert(context.nvim_profile, "typescript verify requires a composed profile")
			local composed
			for _, contribution in ipairs(context.nvim_profile) do
				if contribution.id == intent.id then
					composed = contribution
					break
				end
			end
			assert(composed, "typescript profile intent is missing from the composed profile")
			leaf.verify_mason(context, composed)
			leaf.verify_module(context, intent.plugin_module)
			leaf.verify_cases(context, intent)
		end,
	}
end
