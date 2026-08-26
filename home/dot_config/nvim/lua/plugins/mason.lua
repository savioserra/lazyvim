return {
	{
		"mason-org/mason.nvim",
		opts = function(_, opts)
			-- The external capability sync restores exact Mason versions itself via
			-- mason-lock.nvim. Disable LazyVim's eager Mason installs in those
			-- short-lived headless processes so Neovim does not exit while background
			-- package installs are still running.
			if vim.env.LAZYVIM_CAPABILITY_SYNC == "1" then
				opts.ensure_installed = {}
			end
		end,
	},
}
