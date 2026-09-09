local function complete_capabilities()
	local capabilities = vim.lsp.protocol.make_client_capabilities()
	local ok, blink = pcall(require, "blink.cmp")
	if ok then
		capabilities = blink.get_lsp_capabilities(capabilities)
	end
	return capabilities
end

return {
	-- Let typescript-tools.nvim own TypeScript/JavaScript LSP setup.
	{
		"neovim/nvim-lspconfig",
		opts = function(_, opts)
			opts.servers = opts.servers or {}
			for _, server in ipairs({ "ts_ls", "tsserver", "vtsls", "tsgo" }) do
				opts.servers[server] = opts.servers[server] or {}
				opts.servers[server].enabled = false
			end

			opts.setup = opts.setup or {}
			opts.setup.ts_ls = nil
			opts.setup.tsserver = nil
			opts.setup.vtsls = nil
			opts.setup.tsgo = nil
		end,
	},

	{
		"pmizio/typescript-tools.nvim",
		-- Listed as a dependency (not wired up via nvim-lspconfig) so blink.cmp
		-- is loaded, with capabilities registered, before complete_capabilities() runs.
		dependencies = { "nvim-lua/plenary.nvim", "neovim/nvim-lspconfig", "saghen/blink.cmp" },
		ft = {
			"javascript",
			"javascriptreact",
			"javascript.jsx",
			"typescript",
			"typescriptreact",
			"typescript.tsx",
		},
		keys = {
			{
				"gD",
				"<cmd>TSToolsGoToSourceDefinition<cr>",
				desc = "Go to source definition",
			},
			{
				"gR",
				"<cmd>TSToolsFileReferences<cr>",
				desc = "File references",
			},
			{
				"<leader>cM",
				"<cmd>TSToolsAddMissingImports<cr>",
				desc = "Add missing imports",
			},
			{
				"<leader>cD",
				"<cmd>TSToolsFixAll<cr>",
				desc = "Fix all diagnostics",
			},
			{
				"<leader>co",
				"<cmd>TSToolsOrganizeImports<cr>",
				desc = "Organize imports",
			},
		},
		opts = {
			settings = {
				separate_diagnostic_server = false,
				expose_as_code_action = "all",
				complete_function_calls = true,
				include_completions_with_insert_text = true,
				tsserver_max_memory = "auto",
				tsserver_file_preferences = {
					includeInlayParameterNameHints = "all",
					includeInlayParameterNameHintsWhenArgumentMatchesName = true,
					includeInlayFunctionLikeReturnTypeHints = true,
					includeInlayFunctionParameterTypeHints = true,
				},
				tsserver_format_options = {
					allowIncompleteCompletions = false,
				},
				code_lens = "off",
				disable_member_code_lens = true,
				jsx_close_tag = {
					enable = true,
					filetypes = { "javascriptreact", "typescriptreact" },
				},
			},
		},
		config = function(_, opts)
			opts.capabilities = complete_capabilities()
			require("typescript-tools").setup(opts)

			-- Work around typescript-tools.nvim bugs that leave `<leader>sS`
			-- (workspace/symbol) stuck loading or silently empty: it resolves the
			-- "current file" via the highest buffer number rather than the real
			-- active buffer, and mishandles the error response's shape, silently
			-- orphaning the request.
			-- https://github.com/pmizio/typescript-tools.nvim/issues/357 -- drop once fixed upstream.
			local ts_filetypes = {
				javascript = true,
				javascriptreact = true,
				["javascript.jsx"] = true,
				typescript = true,
				typescriptreact = true,
				["typescript.tsx"] = true,
			}

			-- Track the most recently entered TS/JS buffer instead of trusting
			-- "current buffer" (the picker steals focus) or any loaded buffer
			-- (wrong project in an Nx-style monorepo with per-app tsconfigs).
			local last_ts_buf_name = nil
			vim.api.nvim_create_autocmd("BufEnter", {
				callback = function(args)
					if vim.bo[args.buf].buflisted and ts_filetypes[vim.bo[args.buf].filetype] then
						last_ts_buf_name = vim.api.nvim_buf_get_name(args.buf)
					end
				end,
			})

			local function find_ts_buf_name()
				local cur = vim.api.nvim_get_current_buf()
				if vim.bo[cur].buflisted and ts_filetypes[vim.bo[cur].filetype] then
					return vim.api.nvim_buf_get_name(cur)
				end

				if last_ts_buf_name and last_ts_buf_name ~= "" then
					return last_ts_buf_name
				end

				for _, buf in ipairs(vim.api.nvim_list_bufs()) do
					if
						vim.api.nvim_buf_is_loaded(buf)
						and vim.bo[buf].buflisted
						and ts_filetypes[vim.bo[buf].filetype]
					then
						return vim.api.nvim_buf_get_name(buf)
					end
				end

				return vim.api.nvim_buf_get_name(cur)
			end

			local ok, workspace_symbol = pcall(require, "typescript-tools.protocol.workspace.symbol")
			if ok then
				local ts_utils = require("typescript-tools.protocol.utils")
				function workspace_symbol.handler(request, response, params)
					local buf_name = find_ts_buf_name()

					request({
						command = "navto",
						arguments = { searchValue = params.query, file = buf_name },
					})

					local body = coroutine.yield()
					if type(body) ~= "table" or not vim.islist(body) then
						response({})
						return
					end

					response(vim.tbl_map(
						function(item)
							return {
								name = item.name,
								kind = ts_utils.get_lsp_symbol_kind(item.kind),
								containerName = item.containerName,
								location = {
									uri = vim.uri_from_fname(item.file),
									range = ts_utils.convert_tsserver_range_to_lsp(item),
								},
								tags = (item.kindModifiers or ""):find("deprecated", 1, true) and { 1 } or nil,
							}
						end,
						vim.tbl_filter(function(item)
							return item.file ~= nil
						end, body)
					))
				end
			end
		end,
	},
}
