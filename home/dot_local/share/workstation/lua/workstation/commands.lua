local M = {}

local default_timeout = 300000

local function output(result)
	local streams = {}
	for _, value in ipairs({ result.stdout, result.stderr }) do
		if value and value ~= "" then
			table.insert(streams, vim.trim(value))
		end
	end
	return table.concat(streams, "\n")
end

---@param command string
---@param args? string[]
---@param options? vim.SystemOpts|{ timeout?: integer }
---@return vim.SystemCompleted
local function run_checked(command, args, options)
	local argv = { command }
	vim.list_extend(argv, args or {})
	options = vim.tbl_extend("force", { text = true, timeout = default_timeout }, options or {})
	local timeout = options.timeout
	options.timeout = nil
	local result = vim.system(argv, options):wait(timeout)
	if result.code ~= 0 then
		local detail = output(result)
		error(
			("%s exited with code %d%s"):format(
				table.concat(argv, " "),
				result.code,
				detail == "" and "" or "\n" .. detail
			)
		)
	end
	return result
end

---@param command string
---@param args? string[]
---@param options? vim.SystemOpts|{ timeout?: integer }
---@return vim.SystemCompleted
function M.execute(command, args, options)
	local result = run_checked(command, args, options)
	if result.stdout and result.stdout ~= "" then
		io.stdout:write(result.stdout)
	end
	if result.stderr and result.stderr ~= "" then
		io.stderr:write(result.stderr)
	end
	return result
end

---@param command string
---@param args? string[]
---@param options? vim.SystemOpts|{ timeout?: integer }
---@return string
function M.capture(command, args, options)
	return vim.trim(run_checked(command, args, options).stdout or "")
end

function M.try_execute(command, args, options)
	return pcall(M.execute, command, args, options)
end

return M
