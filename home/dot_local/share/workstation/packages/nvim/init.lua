local commands = require("workstation.commands")

local module_path = debug.getinfo(1, "S").source:gsub("^@", "")
local child_path = vim.fs.joinpath(vim.fs.dirname(vim.fs.normalize(module_path)), "child.lua")

local function run_child(context, operation, request, inherit_output)
	local request_path = vim.fn.tempname() .. ".json"
	context.paths.write(request_path, vim.json.encode(request or {}))
	local lua = ("local ok, err = xpcall(function() dofile(%q)(%q, %q) end, debug.traceback); if not ok then io.stderr:write(err .. '\\n'); vim.cmd('cquit 1') end"):format(
		child_path,
		operation,
		request_path
	)
	local command = inherit_output and commands.execute or commands.capture
	local ok, result = pcall(command, context.platform.nvim, { "--headless", "-c", "lua " .. lua, "+qa" })
	vim.fs.rm(request_path, { force = true })
	if not ok then
		error(result)
	end
	return result
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
	run_child(context, "messages", {})

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

local function verify_profile(context, profile)
	local mason_lock = read_json(context.paths.join(context.paths.home, ".config", "nvim", "mason-lock.json"), context)
	for _, contribution in ipairs(profile) do
		for _, package_name in ipairs(contribution.mason_packages or {}) do
			assert(mason_lock[package_name], "Neovim profile requires unlocked Mason package " .. package_name)
		end
		if contribution.plugin_module then
			run_child(context, "module", { module = contribution.plugin_module })
		end
	end
end

local function verify_language(context, directory, behavior_case)
	local source = context.paths.join(directory, behavior_case.filename)
	context.paths.write(source, behavior_case.contents)
	run_child(context, "language", { source = source, case = behavior_case })
end

local function verify_formatter(context, directory, behavior_case)
	for name, contents in pairs(behavior_case.project_files or {}) do
		context.paths.write(context.paths.join(directory, name), contents)
	end
	local source = context.paths.join(directory, behavior_case.filename)
	context.paths.write(source, behavior_case.contents)
	run_child(context, "formatter", { source = source })
	assert(
		context.paths.read(source) == behavior_case.expected,
		behavior_case.language .. " formatter did not produce expected output"
	)
end

return function(environment)
	local profile_module = require("packages.nvim.profile")
	local profile = environment.nvim_profile
		or profile_module.load(assert(environment.context, "nvim package requires a runtime context"))
	local requires, seen = { "foundation" }, { foundation = true }
	for _, dependency in ipairs(profile_module.required_capabilities(profile)) do
		if not seen[dependency] then
			table.insert(requires, dependency)
			seen[dependency] = true
		end
	end
	return {
		id = "nvim",
		requires = requires,
		sync = function(context)
			for _, operation in ipairs({
				{ "Restoring Neovim plugins", "lazy-restore" },
				{ "Removing inactive Neovim plugins", "lazy-clean" },
				{ "Restoring Mason packages", "mason" },
				{ "Updating Tree-sitter parsers", "treesitter" },
			}) do
				print("\n  -> " .. operation[1])
				run_child(context, "sync", { operation = operation[2] }, true)
			end
		end,
		verify = function(context)
			verify_locked_state(context)
			verify_profile(context, profile)
			local temporary = vim.fn.tempname()
			vim.fn.mkdir(temporary, "p")
			local ok, failure = pcall(function()
				for _, contribution in ipairs(profile) do
					for _, behavior_case in ipairs(contribution.language_cases or {}) do
						verify_language(context, temporary, behavior_case)
					end
					for _, behavior_case in ipairs(contribution.formatter_cases or {}) do
						verify_formatter(context, temporary, behavior_case)
					end
				end
			end)
			vim.fs.rm(temporary, { recursive = true, force = true })
			if not ok then
				error(failure)
			end
		end,
	}
end
