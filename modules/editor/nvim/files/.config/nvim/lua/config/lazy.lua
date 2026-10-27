local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
	local lazyrepo = "https://github.com/folke/lazy.nvim.git"
	local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
	if vim.v.shell_error ~= 0 then
		vim.api.nvim_echo({
			{ "Failed to clone lazy.nvim:\n", "ErrorMsg" },
			{ out, "WarningMsg" },
			{ "\nPress any key to exit..." },
		}, true, {})
		vim.fn.getchar()
		os.exit(1)
	end
end
vim.opt.rtp:prepend(lazypath)

local profile = require("languages.profile")
local specs = {
	-- LazyVim extras must precede all custom plugin specs.
	{ "LazyVim/LazyVim", import = "lazyvim.plugins" },
}
for _, contribution in ipairs(profile) do
	for _, module in ipairs(contribution.lazyvim_extras or {}) do
		table.insert(specs, { import = module })
	end
end
table.insert(specs, { import = "plugins" })
for _, contribution in ipairs(profile) do
	if contribution.plugin_module then
		table.insert(specs, { import = contribution.plugin_module })
	end
end

require("lazy").setup({
	spec = specs,
	defaults = {
		-- By default, only LazyVim plugins will be lazy-loaded. Your custom plugins will load during startup.
		-- If you know what you're doing, you can set this to `true` to have all your custom plugins lazy-loaded by default.
		lazy = false,
		-- It's recommended to leave version=false for now, since a lot the plugin that support versioning,
		-- have outdated releases, which may break your Neovim install.
		version = false, -- always use the latest git commit
		-- version = "*", -- try installing the latest stable version for plugins that support semver
	},
	install = { colorscheme = { "catppuccin-macchiato", "habamax" } },
	checker = {
		enabled = true, -- check for plugin updates periodically
		notify = false, -- notify on update
	}, -- automatically check for plugin updates
	-- None of the configured plugins need LuaRocks.
	rocks = { enabled = false },
	performance = {
		rtp = {
			-- disable some rtp plugins
			disabled_plugins = {
				"gzip",
				-- "matchit",
				-- "matchparen",
				-- "netrwPlugin",
				"tarPlugin",
				"tohtml",
				"tutor",
				"zipPlugin",
			},
		},
	},
})
