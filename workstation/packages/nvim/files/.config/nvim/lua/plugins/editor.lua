return {
	-- Move lines and visual selections with Alt-j/k.
	{
		"matze/vim-move",
		init = function()
			vim.g.move_map_keys = 0
		end,
		config = function()
			vim.keymap.set("n", "<A-k>", "<Plug>MoveLineUp", { remap = true, silent = true, desc = "Move line up" })
			vim.keymap.set("n", "<A-j>", "<Plug>MoveLineDown", { remap = true, silent = true, desc = "Move line down" })
			vim.keymap.set(
				"x",
				"<A-k>",
				"<Plug>MoveBlockCountLinesUp",
				{ remap = true, silent = true, desc = "Move selection up" }
			)
			vim.keymap.set(
				"x",
				"<A-j>",
				"<Plug>MoveBlockCountLinesDown",
				{ remap = true, silent = true, desc = "Move selection down" }
			)
		end,
	},

	-- Close and rename paired HTML/JSX tags.
	{
		"windwp/nvim-ts-autotag",
		opts = {},
	},

	-- Move seamlessly between Neovim splits and tmux panes.
	{
		"christoomey/vim-tmux-navigator",
		cmd = {
			"TmuxNavigateLeft",
			"TmuxNavigateDown",
			"TmuxNavigateUp",
			"TmuxNavigateRight",
			"TmuxNavigatePrevious",
			"TmuxNavigatorProcessList",
		},
		init = function()
			vim.g.tmux_navigator_no_mappings = 1
			vim.g.tmux_navigator_disable_when_zoomed = 1
		end,
		keys = {
			{ "<C-h>", "<cmd>TmuxNavigateLeft<cr>", desc = "Go to left window" },
			{ "<C-j>", "<cmd>TmuxNavigateDown<cr>", desc = "Go to lower window" },
			{ "<C-k>", "<cmd>TmuxNavigateUp<cr>", desc = "Go to upper window" },
			{ "<C-l>", "<cmd>TmuxNavigateRight<cr>", desc = "Go to right window" },
			{ "<C-\\>", "<cmd>TmuxNavigatePrevious<cr>", desc = "Go to previous window" },
		},
	},

	-- Keep Git operations in Lazygit and use Diffview for visual review/history.
	{
		"sindrets/diffview.nvim",
		cmd = {
			"DiffviewClose",
			"DiffviewFileHistory",
			"DiffviewFocusFiles",
			"DiffviewLog",
			"DiffviewOpen",
			"DiffviewRefresh",
			"DiffviewToggleFiles",
		},
		opts = {
			enhanced_diff_hl = true,
			view = {
				merge_tool = {
					layout = "diff4_mixed",
				},
			},
		},
		keys = {
			{ "<leader>gv", "<cmd>DiffviewOpen<cr>", desc = "Diffview working tree" },
			{ "<leader>gV", "<cmd>DiffviewFileHistory<cr>", desc = "Diffview branch history" },
			{ "<leader>gF", "<cmd>DiffviewFileHistory %<cr>", desc = "Diffview file history" },
			{ "<leader>gq", "<cmd>DiffviewClose<cr>", desc = "Close Diffview" },
		},
	},
}
