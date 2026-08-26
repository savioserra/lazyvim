local commands = require("setup.commands")

local M = {}

function M.read(name)
	local ok, output = pcall(commands.capture, "reg.exe", { "query", "HKCU\\Environment", "/v", name })
	if not ok then
		return ""
	end
	for line in output:gmatch("[^\r\n]+") do
		if vim.trim(line):sub(1, #name) == name then
			return vim.trim(line:match("REG_EXPAND_SZ%s+(.+)") or line:match("REG_SZ%s+(.+)") or "")
		end
	end
	return ""
end

function M.write(name, value, expandable)
	if M.read(name) == value then
		return
	end
	commands.execute(
		"reg.exe",
		{ "add", "HKCU\\Environment", "/v", name, "/t", expandable and "REG_EXPAND_SZ" or "REG_SZ", "/d", value, "/f" }
	)
end

local function path_key(path)
	return path:gsub("\\", "/"):gsub("/+$", ""):lower()
end

function M.merge_path(current, required)
	local managed = {}
	for _, entry in ipairs(required) do
		managed[path_key(entry)] = true
	end
	local result, seen = {}, {}
	local function add(entry)
		local key = path_key(entry)
		if key ~= "" and not seen[key] then
			seen[key] = true
			table.insert(result, entry)
		end
	end
	for _, entry in ipairs(required) do
		add(entry)
	end
	for _, entry in ipairs(vim.split(current, ";", { trimempty = true })) do
		if not managed[path_key(entry)] then
			add(entry)
		end
	end
	return table.concat(result, ";")
end

function M.same_path(left, right)
	return path_key(left) == path_key(right)
end

return M
