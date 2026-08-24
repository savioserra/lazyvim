local M = {}

local function invoke(command, args, options)
	local argv = { command }
	vim.list_extend(argv, args or {})
	local result = vim.system(argv, vim.tbl_extend("force", { text = true }, options or {})):wait()
	if result.code ~= 0 then
		error(("%s exited with code %d\n%s"):format(command, result.code, result.stderr or result.stdout or ""))
	end
	return result
end

function M.execute(command, args, options)
	local result = invoke(command, args, options)
	if result.stdout and result.stdout ~= "" then
		io.stdout:write(result.stdout)
	end
	if result.stderr and result.stderr ~= "" then
		io.stderr:write(result.stderr)
	end
end

function M.capture(command, args, options)
	return vim.trim(invoke(command, args, options).stdout or "")
end

function M.try_execute(command, args, options)
	return pcall(M.execute, command, args, options)
end

return M
