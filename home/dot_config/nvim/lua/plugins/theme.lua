-- Omarchy atomically swaps the active desktop theme at a stable path; its
-- neovim.lua returns a lazy.nvim spec selecting the theme colorscheme. Import
-- it when present so the editor follows the desktop theme, and fall back to
-- tender everywhere else: macOS, WSL, plain Linux, and Omarchy themes that
-- ship no neovim.lua.
local function omarchy_theme_specs()
	local candidates = {
		vim.fn.expand("~/.local/state/omarchy/current/theme/neovim.lua"),
		vim.fn.expand("~/.config/omarchy/current/theme/neovim.lua"),
	}

	for _, path in ipairs(candidates) do
		local chunk = loadfile(path)
		if chunk then
			local ok, specs = pcall(chunk)
			if ok and type(specs) == "table" and #specs > 0 then
				return specs
			end
		end
	end

	return nil
end

local omarchy_specs = omarchy_theme_specs()

local specs = {
	{
		"jacoborus/tender.vim",
		lazy = false,
		priority = 1000,
		config = function()
			-- Keep tender.vim installed for stable lockfile state, but let the
			-- imported Omarchy colorscheme own startup when one is active.
			if omarchy_specs then
				return
			end

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

if omarchy_specs then
	-- Append after the tender LazyVim spec so the Omarchy spec's own
	-- LazyVim colorscheme override wins lazy.nvim's later-spec-wins opts merge.
	vim.list_extend(specs, omarchy_specs)
end

return specs
