local function complete_capabilities()
	local capabilities = vim.lsp.protocol.make_client_capabilities()
	local ok, blink = pcall(require, "blink.cmp")
	if ok then
		capabilities = blink.get_lsp_capabilities(capabilities)
	end
	return capabilities
end

-- TS_ENGINE=tsgo swaps the TypeScript LSP from typescript-tools.nvim (classic JS
-- tsserver plus the handler patches below) to the native tsgo language server
-- (@typescript/native-preview pinned per workspace, plain LSP, no patches needed).
local native_ts = vim.env.TS_ENGINE == "tsgo"

return {
	-- Owns which server provides TypeScript/JavaScript LSP: typescript-tools.nvim
	-- by default, tsgo when TS_ENGINE=tsgo. The other stock TS servers stay off in
	-- both modes so exactly one engine attaches.
	{
		"neovim/nvim-lspconfig",
		opts = function(_, opts)
			opts.servers = opts.servers or {}
			for _, server in ipairs({ "ts_ls", "tsserver", "vtsls" }) do
				opts.servers[server] = opts.servers[server] or {}
				opts.servers[server].enabled = false
			end

			opts.setup = opts.setup or {}
			opts.setup.ts_ls = nil
			opts.setup.tsserver = nil
			opts.setup.vtsls = nil
			opts.setup.tsgo = nil

			if native_ts then
				-- Prefer the workspace-local tsgo binary so each repo pins its own
				-- @typescript/native-preview version; global tsgo as fallback.
				-- enabled/mason must be forced: the lang.typescript extra gates all TS
				-- engines off except its selector (vtsls by default), and mason knows
				-- tsgo, which would route setup through its own installer otherwise.
				local bin = vim.fs.find("node_modules/.bin/tsgo", { upward = true, path = vim.uv.cwd() })[1]
				opts.servers.tsgo = vim.tbl_deep_extend("force", opts.servers.tsgo or {}, {
					enabled = true,
					mason = false,
					cmd = { bin or "tsgo", "--lsp", "--stdio" },
					capabilities = complete_capabilities(),
				})
			else
				opts.servers.tsgo = opts.servers.tsgo or {}
				opts.servers.tsgo.enabled = false
			end
		end,
	},

	{
		"pmizio/typescript-tools.nvim",
		enabled = not native_ts,
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
				include_completions_with_insert_text = true,
				-- Must be a number: "auto" is a no-op in typescript-tools.nvim, spawning
				-- tsserver without --max-old-space-size (V8 default ~4GB, which large
				-- monorepos exceed, causing GC pauses and heap-OOM restarts).
				tsserver_max_memory = 8192,
				tsserver_file_preferences = {
					includeInlayParameterNameHints = "all",
					includeInlayParameterNameHintsWhenArgumentMatchesName = true,
					includeInlayFunctionLikeReturnTypeHints = true,
					includeInlayFunctionParameterTypeHints = true,
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
			-- The navto request below deliberately omits `file`: with it, tsserver
			-- scopes the search to that file's project only (one tsconfig in Nx-style
			-- monorepos, hiding symbols from sibling apps/libs); without it, it
			-- searches every loaded project and dedupes results across them.
			local ok, workspace_symbol = pcall(require, "typescript-tools.protocol.workspace.symbol")
			if ok then
				local ts_utils = require("typescript-tools.protocol.utils")
				function workspace_symbol.handler(request, response, params)
					request({
						command = "navto",
						arguments = { searchValue = params.query },
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

			-- Serve repeat completion requests at the same cursor position from a
			-- short-lived cache. tsserver recomputes the full auto-import list on every
			-- request (~1s plus a multi-MB payload on large monorepos), and blink.cmp
			-- only reuses lists within a single completion context id, so dismissing
			-- and re-opening the menu re-paid the whole cost. Keyed on buffer
			-- changedtick (any edit invalidates) and position; the TTL bounds staleness
			-- from edits to other files changing tsserver's auto-import universe.
			local ok_completion, completion =
				pcall(require, "typescript-tools.protocol.text_document.completion")
			if ok_completion then
				local completion_handler = completion.handler
				local completion_cache = {}
				function completion.handler(request, response, params)
					local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
					local ok_tick, changedtick = pcall(vim.api.nvim_buf_get_var, bufnr, "changedtick")
					local context = params.context or {}
					local key = string.format(
						"%s|%s|%d|%d|%s|%s",
						params.textDocument.uri,
						tostring(ok_tick and changedtick or -1),
						params.position.line,
						params.position.character,
						tostring(context.triggerKind),
						tostring(context.triggerCharacter)
					)
					if completion_cache.key == key and (vim.uv.now() - completion_cache.time) < 3000 then
						response(completion_cache.response)
						return
					end

					completion_handler(request, function(resp)
						completion_cache.key = key
						completion_cache.time = vim.uv.now()
						completion_cache.response = resp
						response(resp)
					end, params)
				end
			end
		end,
	},
}
