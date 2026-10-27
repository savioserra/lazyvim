local M = {}

local function lazy_operation(operation)
	local handler = assert(require("lazy")[operation], "unknown lazy operation: " .. operation)
	handler({ wait = true, show = false })
end

local operations = {
	["lazy-restore"] = function()
		lazy_operation("restore")
	end,
	["lazy-clean"] = function()
		lazy_operation("clean")
	end,
	mason = function()
		require("mason-lock").restore_from_lockfile()
	end,
	treesitter = function()
		local config = require("nvim-treesitter.config")
		local parser_dir = config.get_install_dir("parser")
		local info_dir = config.get_install_dir("parser-info")
		vim.fn.mkdir(info_dir, "p")

		-- LazyVim can begin installing parsers during startup. If another headless
		-- sync operation exits between writing the parser and its revision file,
		-- nvim-treesitter's updater assumes the missing file exists and aborts.
		-- An empty revision safely marks that parser for a forced refresh below.
		if vim.fn.isdirectory(parser_dir) == 1 then
			for name, kind in vim.fs.dir(parser_dir) do
				if kind == "file" then
					local language = name:match("^(.+)%.[^.]+$")
					local revision = language and vim.fs.joinpath(info_dir, language .. ".revision")
					if revision and vim.fn.filereadable(revision) == 0 then
						vim.fn.writefile({}, revision)
					end
				end
			end
		end

		local plugin = assert(require("lazy.core.config").plugins["nvim-treesitter"])
		local opts = require("lazy.core.plugin").values(plugin, "opts", false)
		local treesitter = require("nvim-treesitter")
		local installed = treesitter.install(opts.ensure_installed or {}, { summary = true }):wait(300000)
		assert(installed, "Tree-sitter parser install failed")
		local updated = treesitter.update(nil, { summary = true }):wait(300000)
		assert(updated, "Tree-sitter parser update failed")
	end,
}

function M.run(operation)
	local handler = assert(operations[operation], "unknown sync operation: " .. tostring(operation))
	handler()
end

return M
