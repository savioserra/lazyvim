return {
	{
		"mason-org/mason.nvim",
		opts = function(_, opts)
			-- The headless sync restores exact Mason versions via mason-lock.nvim.
			-- Disable eager installs in those short-lived processes so Neovim does
			-- not exit while background package installs are still running.
			if vim.env.LAZYVIM_HEADLESS_SYNC == "1" then
				opts.ensure_installed = {}
			end
		end,
	},
}
