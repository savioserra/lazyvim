-- Starlight via oasis.nvim — the same palette family as every other
-- workstation surface (theme tokens cite the upstream starlight palette).
-- Upstream switches dark/light on vim.o.background, so both appearances
-- map natively.
local specs = {
	{
		"uhs-robert/oasis.nvim",
		lazy = false,
		priority = 1000,
		config = function()
			-- `style` is the setup contract key (README configuration block);
			-- `light_intensity` 3 is already the upstream default.
			require("oasis").setup({ style = "starlight" })
			vim.cmd.colorscheme("oasis-starlight")
		end,
	},

	{
		"LazyVim/LazyVim",
		opts = {
			colorscheme = "oasis-starlight",
		},
	},
}

return specs
