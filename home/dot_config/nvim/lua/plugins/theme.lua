return {
	{
		"jacoborus/tender.vim",
		lazy = false,
		priority = 1000,
		config = function()
			vim.cmd.colorscheme("tender")

			-- tender.vim gives floats/completion a blue-tinted bg (#335261) that its
			-- own text colors (tuned against the main #282828 bg) read poorly
			-- against; repoint those surfaces to the main bg's neutral dark family.
			-- Also fixes FloatBorder (fg == bg, invisible) and LspInlayHint
			-- (#444444, too dark to read) using tender's own palette.
			local function fix_tender_contrast()
				vim.api.nvim_set_hl(0, "NormalFloat", { bg = "#202020", fg = "#eeeeee" })
				vim.api.nvim_set_hl(0, "FloatBorder", { bg = "#202020", fg = "#999999" })
				vim.api.nvim_set_hl(0, "Pmenu", { bg = "#202020", fg = "#eeeeee" })
				vim.api.nvim_set_hl(0, "Visual", { bg = "#323232" })
				vim.api.nvim_set_hl(0, "LspInlayHint", { fg = "#999999" })
			end

			fix_tender_contrast()
			vim.api.nvim_create_autocmd("ColorScheme", {
				pattern = "tender",
				callback = fix_tender_contrast,
			})
		end,
	},
	{
		"LazyVim/LazyVim",
		opts = {
			colorscheme = "tender",
		},
	},
}
