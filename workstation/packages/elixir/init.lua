local leaf = require("packages.nvim.leaf")
local profile_module = require("packages.nvim.profile")
local provision = require("workstation.provision.recipes")

-- The elixir capability: a language package that owns the Elixir/HEEx editor
-- integration on top of the nvim capability. The BEAM toolchain (elixir/erlang
-- resolvable on PATH, mise- or system-managed) is a host prerequisite, not an
-- engine-owned runtime: there is no elixir runtime capability yet, so this is
-- one step looser than typescript, whose Node toolchain the node capability
-- owns end to end.
--
-- ElixirLS is the language's only real LSP, so ownership is about constraining
-- it rather than replacing nvim-lspconfig like typescript-tools does:
-- formatting is pinned to the deterministic `mix format` CLI through conform
-- (ElixirLS formatting would make on-save output depend on a live BEAM
-- server), and the slow optional subsystems (dialyzer, dep fetching) stay off
-- so LSP attach and the headless verification cases stay deterministic.

local intent = {
	id = "elixir",
	plugin_module = "languages.plugins.elixir",
	lazyvim_extras = {
		"lazyvim.plugins.extras.lang.elixir",
	},
	mason_packages = { "elixir-ls" },
	language_cases = {
		{
			language = "elixir",
			filename = "behavior-test.ex",
			contents = "defmodule Behavior do\n  def answer, do: 42\nend\n",
			-- The lspconfig server name, not the Mason package name: Mason ships
			-- "elixir-ls" while the attached client calls itself "elixirls".
			client = "elixirls",
		},
	},
	formatter_cases = {
		{
			language = "elixir",
			filename = "format-test.ex",
			contents = "defmodule T do\ndef answer do\n42\nend\nend\n",
			expected = "defmodule T do\n  def answer do\n    42\n  end\nend\n",
			-- conform's `mix` formatter chdirs to the mix.exs root, so the
			-- formatter case needs a minimal project, not just a bare source
			-- file (mix format itself needs no dependencies or compilation).
			project_files = {
				["mix.exs"] = table.concat({
					"defmodule FormatTest.MixProject do",
					"  use Mix.Project",
					"",
					"  def project do",
					'    [app: :format_test, version: "0.1.0"]',
					"  end",
					"end",
					"",
				}, "\n"),
			},
		},
	},
}

return function()
	return {
		id = "elixir",
		requires = { "nvim" },
		contributes = {
			profile_module.recipe({ order = 25, entry = intent }),
			provision.chezmoi({
				target = ".config/nvim/lua/languages/plugins/elixir.lua",
				kind = "file",
				asset = "files/languages/plugins/elixir.lua",
			}),
		},
		verify = function(context)
			assert(context.nvim_profile, "elixir verify requires a composed profile")
			local composed
			for _, contribution in ipairs(context.nvim_profile) do
				if contribution.id == intent.id then
					composed = contribution
					break
				end
			end
			assert(composed, "elixir profile intent is missing from the composed profile")
			leaf.verify_mason(context, composed)
			leaf.verify_module(context, intent.plugin_module)
			leaf.verify_cases(context, intent)
		end,
	}
end
