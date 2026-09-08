local function read_json(path)
	local file = assert(io.open(path, "rb"))
	local contents = file:read("*a")
	file:close()
	return vim.json.decode(contents)
end

local operations = {}

function operations.sync(request)
	require("config.sync").run(request.operation)
end

function operations.messages()
	local messages = vim.api.nvim_exec2("messages", { output = true }).output
	if messages:find("order of your `lazy.nvim` imports", 1, true) then
		error("LazyVim reported invalid import order")
	end
end

function operations.module(request)
	assert(type(require(request.module)) == "table", "invalid profile plugin module")
end

function operations.language(request)
	vim.cmd("edit " .. vim.fn.fnameescape(request.source))
	local parser_ok, parser = pcall(vim.treesitter.get_parser, 0)
	if not parser_ok or parser == nil then
		error(request.case.language .. " parser unavailable: " .. tostring(parser))
	end
	parser:parse()
	local attached = vim.wait(15000, function()
		for _, client in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
			if client.name == request.case.client then
				return true
			end
		end
		return false
	end, 100)
	assert(attached, request.case.client .. " did not attach to " .. request.case.language)
end

function operations.formatter(request)
	vim.cmd("edit " .. vim.fn.fnameescape(request.source))
	require("conform").format({ async = false, timeout_ms = 15000 })
	vim.cmd("write")
end

return function(operation, request_path)
	local handler = assert(operations[operation], "unknown Neovim child operation: " .. tostring(operation))
	handler(read_json(request_path))
end
