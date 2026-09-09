local commands = require("workstation.commands")

-- nvim-owned leaf verification helpers. Extracted from the nvim package so a
-- language capability like typescript can verify its own plugin module, Mason
-- expectations and behavior/formatter cases through the exact same headless
-- child machinery, while nvim keeps base/standard/Go and lock verification.

local module_path = debug.getinfo(1, "S").source:gsub("^@", "")
local child_path = vim.fs.joinpath(vim.fs.dirname(vim.fs.normalize(module_path)), "child.lua")

local M = {}

function M.run_child(context, operation, request, inherit_output)
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

function M.verify_module(context, module)
	M.run_child(context, "module", { module = module })
end

---Every declared Mason expectation must exist in the applied mason lock.
function M.verify_mason(context, contribution)
	local config = context.paths.join(context.paths.home, ".config", "nvim")
	local file = assert(io.open(context.paths.join(config, "mason-lock.json"), "rb"))
	local lock = vim.json.decode(file:read("*a"))
	file:close()
	for _, package_name in ipairs(contribution.mason_packages or {}) do
		assert(lock[package_name], "Neovim profile requires unlocked Mason package " .. package_name)
	end
end

function M.verify_language(context, directory, behavior_case)
	local source = context.paths.join(directory, behavior_case.filename)
	context.paths.write(source, behavior_case.contents)
	M.run_child(context, "language", { source = source, case = behavior_case })
end

function M.verify_formatter(context, directory, behavior_case)
	for name, contents in pairs(behavior_case.project_files or {}) do
		context.paths.write(context.paths.join(directory, name), contents)
	end
	local source = context.paths.join(directory, behavior_case.filename)
	context.paths.write(source, behavior_case.contents)
	M.run_child(context, "formatter", { source = source })
	assert(
		context.paths.read(source) == behavior_case.expected,
		behavior_case.language .. " formatter did not produce expected output"
	)
end

---Verify every behavior and formatter case of one language contribution.
function M.verify_cases(context, contribution)
	local temporary = vim.fn.tempname()
	vim.fn.mkdir(temporary, "p")
	local ok, failure = pcall(function()
		for _, behavior_case in ipairs(contribution.language_cases or {}) do
			M.verify_language(context, temporary, behavior_case)
		end
		for _, behavior_case in ipairs(contribution.formatter_cases or {}) do
			M.verify_formatter(context, temporary, behavior_case)
		end
	end)
	vim.fs.rm(temporary, { recursive = true, force = true })
	if not ok then
		error(failure)
	end
end

return M
