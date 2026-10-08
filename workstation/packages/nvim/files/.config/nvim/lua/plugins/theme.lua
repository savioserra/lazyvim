-- Starlight via oasis.nvim — the same brand as every other workstation
-- surface (theme tokens v4 cite the upstream starlight palette, so editor
-- and engine render one family). Upstream switches dark/light on
-- vim.o.background, so both appearances map natively. The Omarchy
-- desktop-theme import was dropped with the Starlight rebrand: starlight
-- wins on all hosts (rebrand spec S-R2), so there is no precedence to
-- guard anymore.
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
