local commands = require("setup.commands")
local define = require("setup.contract")

local function run_lua(executable, lua, inherit_output)
	local args = { "--headless", "-c", "lua " .. lua, "+qa" }
	if inherit_output then
		commands.execute(executable, args)
	else
		commands.capture(executable, args)
	end
end

local function read_json(path, context)
	return vim.json.decode(context.paths.read(path))
end

local function verify_locked_state(context)
	local first_line = vim.split(commands.capture(context.platform.nvim, { "--version" }), "\n")[1]
	assert(first_line == "NVIM v" .. context.versions.neovim, "Unexpected Neovim: " .. first_line)
	assert(
		vim.split(commands.capture("nvim", { "--version" }), "\n")[1] == first_line,
		"Configured environment does not resolve managed Neovim"
	)
	run_lua(
		context.platform.nvim,
		table.concat({
			"local messages = vim.api.nvim_exec2('messages', { output = true }).output",
			"if messages:find('order of your `lazy.nvim` imports', 1, true) then error('LazyVim reported invalid import order') end",
		}, "; ")
	)

	local config = context.paths.join(context.paths.home, ".config", "nvim")
	for _, lock in ipairs({
		{ "lazy-lock.json", context.paths.join(context.platform.nvim_data(), "lazy") },
		{ "mason-lock.json", context.paths.join(context.platform.nvim_data(), "mason", "packages") },
	}) do
		for name in pairs(read_json(context.paths.join(config, lock[1]), context)) do
			assert(context.paths.exists(context.paths.join(lock[2], name)), "Missing " .. lock[1] .. " entry: " .. name)
		end
	end
end

local function verify_enhancements(context)
	local mason_lock = read_json(context.paths.join(context.paths.home, ".config", "nvim", "mason-lock.json"), context)
	for _, enhancement in ipairs(context.enhancements) do
		for _, package_name in ipairs(enhancement.mason_packages or {}) do
			assert(mason_lock[package_name], "Neovim enhancement requires unlocked Mason package " .. package_name)
		end
		if enhancement.extras_module then
			local extras_json = vim.json.encode(enhancement.lazyvim_extras or {})
			run_lua(
				context.platform.nvim,
				table.concat({
					("local spec = require(%q)"):format(enhancement.extras_module),
					"local imports = {}",
					"for _, item in ipairs(spec) do if item.import then imports[item.import] = true end end",
					("for _, name in ipairs(vim.json.decode(%q)) do if not imports[name] then error('missing capability import: ' .. name) end end"):format(
						extras_json
					),
				}, "; ")
			)
		end
		if enhancement.plugin_module then
			run_lua(
				context.platform.nvim,
				("assert(type(require(%q)) == 'table', 'invalid capability plugin module')"):format(
					enhancement.plugin_module
				)
			)
		end
	end
end

local function verify_language(context, directory, behavior_case)
	local source = context.paths.join(directory, behavior_case.filename)
	context.paths.write(source, behavior_case.contents)
	run_lua(
		context.platform.nvim,
		table.concat({
			("vim.cmd('edit ' .. vim.fn.fnameescape(%q))"):format(source),
			"local parser_ok, parser = pcall(vim.treesitter.get_parser, 0)",
			("if not parser_ok then error(%q .. tostring(parser)) end"):format(
				behavior_case.language .. " parser unavailable: "
			),
			"parser:parse()",
			"local attached = vim.wait(15000, function() for _, client in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do",
			("if client.name == %q then return true end"):format(behavior_case.client),
			"end return false end, 100)",
			("if not attached then error(%q) end"):format(
				behavior_case.client .. " did not attach to " .. behavior_case.language
			),
		}, "; ")
	)
end

local function verify_formatter(context, directory, behavior_case)
	for name, contents in pairs(behavior_case.project_files or {}) do
		context.paths.write(context.paths.join(directory, name), contents)
	end
	local source = context.paths.join(directory, behavior_case.filename)
	context.paths.write(source, behavior_case.contents)
	run_lua(
		context.platform.nvim,
		table.concat({
			("vim.cmd('edit ' .. vim.fn.fnameescape(%q))"):format(source),
			"require('conform').format({ async = false, timeout_ms = 15000 })",
			"vim.cmd('write')",
		}, "; ")
	)
	assert(
		context.paths.read(source) == behavior_case.expected,
		behavior_case.language .. " formatter did not produce expected output"
	)
end

return define({
	id = "nvim",
	requires = { "foundation", "language.node" },
	sync = function(context)
		for _, operation in ipairs({
			{ "Restoring Neovim plugins", "lazy-restore" },
			{ "Removing inactive Neovim plugins", "lazy-clean" },
			{ "Restoring Mason packages", "mason" },
			{ "Updating Tree-sitter parsers", "treesitter" },
		}) do
			print("\n  -> " .. operation[1])
			local lua = ("local ok, err = xpcall(function() require('config.sync').run(%q) end, debug.traceback); if not ok then io.stderr:write(err .. '\\n'); vim.cmd('cquit 1') end"):format(
				operation[2]
			)
			run_lua(context.platform.nvim, lua, true)
		end
	end,
	verify = function(context)
		verify_locked_state(context)
		verify_enhancements(context)
		local temporary = vim.fn.tempname()
		vim.fn.mkdir(temporary, "p")
		local ok, failure = pcall(function()
			for _, enhancement in ipairs(context.enhancements) do
				for _, behavior_case in ipairs(enhancement.language_cases or {}) do
					verify_language(context, temporary, behavior_case)
				end
				for _, behavior_case in ipairs(enhancement.formatter_cases or {}) do
					verify_formatter(context, temporary, behavior_case)
				end
			end
		end)
		vim.fs.rm(temporary, { recursive = true, force = true })
		if not ok then
			error(failure)
		end
	end,
})
