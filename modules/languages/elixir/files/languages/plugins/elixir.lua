return {
	{
		"neovim/nvim-lspconfig",
		opts = function(_, opts)
			opts.servers = opts.servers or {}
			opts.servers.elixirls = opts.servers.elixirls or {}
			-- ElixirLS's dialyzer integration and dependency fetching run as
			-- minutes-long background jobs that would make LSP attach (and the
			-- capability's headless verification case) nondeterministic; run
			-- dialyzer and deps.get explicitly through mix instead of letting
			-- the server decide when.
			opts.servers.elixirls.settings = {
				elixirLS = {
					dialyzerEnabled = false,
					fetchDeps = false,
				},
			}
		end,
	},
	{
		"stevearc/conform.nvim",
		optional = true,
		opts = function(_, opts)
			-- conform owns Elixir autoformatting: `mix format` is the canonical
			-- deterministic formatter, works with no running ElixirLS, and is
			-- what the capability's formatter case pins. ElixirLS's own
			-- textDocument/formatting stays reachable for manual gq use but is
			-- never in the autoformat chain, so a stalled BEAM server can never
			-- wedge formatting.
			opts.formatters_by_ft = opts.formatters_by_ft or {}
			opts.formatters_by_ft.elixir = { "mix" }
		end,
	},
}
