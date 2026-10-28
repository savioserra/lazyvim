return {
	{
		"neovim/nvim-lspconfig",
		opts = function(_, opts)
			opts.servers = opts.servers or {}
			opts.servers.gopls = opts.servers.gopls or {}
			-- merge, never overwrite: the lang.go extra carries its own
			-- gopls configuration; this module adds the workspace analysis
			-- the capability leans on (unused-variable diagnostics in the
			-- edited buffer, no external analyzer dependency)
			opts.servers.gopls.settings = vim.tbl_deep_extend("force", opts.servers.gopls.settings or {}, {
				gopls = {
					analyses = {
						unusedvariable = true,
					},
				},
			})
		end,
	},
	{
		"stevearc/conform.nvim",
		optional = true,
		opts = function(_, opts)
			-- gofmt ships inside the toolchain the go capability deploys:
			-- the canonical deterministic formatter, no extra install
			opts.formatters_by_ft = opts.formatters_by_ft or {}
			opts.formatters_by_ft.go = { "gofmt" }
		end,
	},
}
