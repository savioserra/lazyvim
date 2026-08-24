local root = vim.fs.joinpath(vim.fn.getcwd(), "home", "dot_local", "share", "lazyvim")
package.path = table.concat({
	vim.fs.joinpath(root, "lua", "?.lua"),
	vim.fs.joinpath(root, "lua", "?", "init.lua"),
	package.path,
}, ";")

local registry = require("lazyvim_capabilities.registry")

local function assert_contains(values, expected)
	assert(vim.list_contains(values, expected), ("expected %s in [%s]"):format(expected, table.concat(values, ", ")))
end

local function ids_for(platform_name)
	local result = registry.create({ platform = { name = platform_name } })
	return vim.tbl_map(function(capability)
		return capability.id
	end, result.ordered)
end

local windows = ids_for("win32")
assert(not vim.list_contains(windows, "tmux"), "Windows must omit tmux")
assert_contains(windows, "nvim")
assert_contains(windows, "language.typescript")

local linux = ids_for("linux")
assert_contains(linux, "tmux")
assert(vim.list_contains(linux, "foundation"), "Linux must include foundation")
local foundation_index = vim.iter(linux):enumerate():find(function(_, id)
	return id == "foundation"
end)
local tmux_index = vim.iter(linux):enumerate():find(function(_, id)
	return id == "tmux"
end)
assert(foundation_index < tmux_index, "foundation must run before tmux")

local composed = registry.create({ platform = { name = "linux" } })
local enhancements = composed:enhancements_for("nvim")
local clients = {}
local has_formatter = false
for _, enhancement in ipairs(enhancements) do
	for _, case in ipairs(enhancement.language_cases or {}) do
		table.insert(clients, case.client)
	end
	has_formatter = has_formatter or #(enhancement.formatter_cases or {}) > 0
end
assert_contains(clients, "typescript-tools")
assert_contains(clients, "gopls")
assert(has_formatter, "language enhancements must contribute formatter behavior")

print("capability composition tests passed")
