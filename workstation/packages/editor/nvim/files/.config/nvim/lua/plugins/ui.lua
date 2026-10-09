return {
	-- Use Snacks as the shared picker, explorer, dashboard, and notification UI.
	-- Animated scrolling stays disabled so the interface remains immediate over tmux/SSH.
	{
		"folke/snacks.nvim",
		opts = {
			scroll = { enabled = false },
			notifier = {
				enabled = true,
				style = "compact",
				timeout = 3000,
			},
		},
	},

	-- Prefer the buffer picker and native tab pages over a permanently redrawn tabline.
	{
		"akinsho/bufferline.nvim",
		enabled = false,
	},
	{
		"nvim-lualine/lualine.nvim",
		opts = function(_, opts)
			local icons = LazyVim.config.icons
			opts.options = vim.tbl_deep_extend("force", opts.options or {}, {
				globalstatus = true,
				component_separators = { left = "│", right = "│" },
				section_separators = { left = "", right = "" },
			})
			opts.sections = {
				lualine_a = {
					{
						"mode",
						fmt = function(mode)
							return mode:sub(1, 1)
						end,
					},
				},
				lualine_b = { "branch" },
				lualine_c = {
					{
						"filename",
						path = 1,
						symbols = {
							modified = " ●",
							readonly = " ",
							unnamed = "[No Name]",
							newfile = " ",
						},
					},
				},
				lualine_x = {
					{
						"diagnostics",
						symbols = {
							error = icons.diagnostics.Error,
							warn = icons.diagnostics.Warn,
							info = icons.diagnostics.Info,
							hint = icons.diagnostics.Hint,
						},
					},
					{
						"diff",
						symbols = {
							added = icons.git.added,
							modified = icons.git.modified,
							removed = icons.git.removed,
						},
						source = function()
							local status = vim.b.gitsigns_status_dict
							return status
								and {
									added = status.added,
									modified = status.changed,
									removed = status.removed,
								}
						end,
					},
					{
						function()
							return "  " .. require("dap").status()
						end,
						cond = function()
							return package.loaded.dap and require("dap").status() ~= ""
						end,
						color = function()
							return { fg = Snacks.util.color("Debug") }
						end,
					},
					{ "filetype", icon_only = true, separator = "", padding = { left = 1, right = 1 } },
				},
				lualine_y = { "progress" },
				lualine_z = { "location" },
			}
			return opts
		end,
	},

	-- Keep Noice's polished command palette, but leave messages, notifications,
	-- completion, and LSP popups to Neovim, Snacks, and blink.cmp.
	{
		"folke/noice.nvim",
		opts = {
			cmdline = {
				enabled = true,
				view = "cmdline_popup",
			},
			messages = { enabled = false },
			popupmenu = { enabled = false },
			notify = { enabled = false },
			lsp = {
				progress = { enabled = false },
				hover = { enabled = false },
				signature = { enabled = false },
				override = {
					["vim.lsp.util.convert_input_to_markdown_lines"] = false,
					["vim.lsp.util.stylize_markdown"] = false,
					["cmp.entry.get_documentation"] = false,
				},
			},
			presets = {
				bottom_search = true,
				command_palette = false,
				long_message_to_split = false,
			},
		},
		keys = {
			{ "<leader>sn", false },
			{ "<leader>snl", false },
			{ "<leader>snh", false },
			{ "<leader>sna", false },
			{ "<leader>snd", false },
			{ "<leader>snt", false },
			{ "<C-f>", false, mode = { "i", "n", "s" } },
			{ "<C-b>", false, mode = { "i", "n", "s" } },
		},
	},

	-- Interactive IDE-style breadcrumbs replace the static Treesitter Context row.
	{
		"Bekaboo/dropbar.nvim",
		event = "LazyFile",
		opts = {
			bar = {
				update_debounce = 48,
			},
		},
		keys = {
			{
				"<leader>;",
				function()
					require("dropbar.api").pick()
				end,
				desc = "Pick breadcrumb",
			},
			{
				"[;",
				function()
					require("dropbar.api").goto_context_start()
				end,
				desc = "Breadcrumb context start",
			},
			{
				"];",
				function()
					require("dropbar.api").select_next_context()
				end,
				desc = "Next breadcrumb context",
			},
		},
	},

	-- Replace diagnostic virtual text with a cleaner inline display.
	{
		"rachartier/tiny-inline-diagnostic.nvim",
		event = "VeryLazy",
		priority = 1000,
		opts = {
			preset = "modern",
		},
	},
	{
		"neovim/nvim-lspconfig",
		opts = {
			diagnostics = {
				virtual_text = false,
			},
		},
	},
}
