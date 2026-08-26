local root = vim.fs.joinpath(vim.fn.getcwd(), "home", "dot_local", "share", "lazyvim")
package.path = table.concat({
	vim.fs.joinpath(root, "lua", "?.lua"),
	vim.fs.joinpath(root, "lua", "?", "init.lua"),
	package.path,
}, ";")

local commands = require("setup.commands")
local define = require("setup.contract")
local registry = require("setup.registry")

local function assert_contains(values, expected)
	assert(vim.list_contains(values, expected), ("expected %s in [%s]"):format(expected, table.concat(values, ", ")))
end

local function assert_fails(pattern, callback)
	local ok, failure = pcall(callback)
	assert(not ok, "expected operation to fail")
	assert(
		tostring(failure):find(pattern, 1, true),
		("expected failure containing %q, got %q"):format(pattern, failure)
	)
end

local function capability(id, requires, options)
	return define(vim.tbl_extend("force", {
		id = id,
		requires = requires or {},
	}, options or {}))
end

local function ids_for(platform_name)
	local result = registry.create({ platform = { name = platform_name } })
	return vim.tbl_map(function(item)
		return item.id
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

local test_context = { platform = { name = "test" } }
assert_fails("duplicate capability", function()
	registry.create(test_context, { capability("same"), capability("same") })
end)
assert_fails("requires unknown capability", function()
	registry.create(test_context, { capability("dependent", { "missing" }) })
end)
assert_fails("dependency cycle", function()
	registry.create(test_context, { capability("a", { "b" }), capability("b", { "a" }) })
end)
assert_fails("requires unsupported capability", function()
	registry.create(test_context, {
		capability("unsupported", nil, {
			supports = function()
				return false
			end,
		}),
		capability("dependent", { "unsupported" }),
	})
end)
assert_fails("supports must return a boolean", function()
	registry.create(test_context, {
		capability("invalid", nil, {
			supports = function()
				return "yes"
			end,
		}),
	})
end)
assert_fails("requires[1] must be a non-empty string", function()
	capability("invalid", { 42 })
end)
assert_fails("language_cases[1].client must be a non-empty string", function()
	capability("invalid", nil, {
		enhancements = {
			nvim = {
				{
					language_cases = {
						{ language = "lua", filename = "test.lua", contents = "return true\n" },
					},
				},
			},
		},
	})
end)

package.loaded["setup.platforms.linux"] = nil
package.loaded["setup.platforms.macos"] = nil
local linux_adapter = require("setup.platforms.linux")
local macos_adapter = require("setup.platforms.macos")
assert(not rawequal(linux_adapter, macos_adapter), "platform adapters must be independent tables")
assert(linux_adapter.name == "linux", "loading macOS must not mutate Linux")
assert(macos_adapter.name == "darwin", "macOS adapter has the wrong name")

local windows_adapter = require("setup.platforms.windows")
local required = { "C:/managed/bin", "C:/managed/node" }
local merged = windows_adapter.merge_path(
	"C:\\legacy\\node;C:\\managed\\bin;C:/managed/bin/;C:\\Windows;C:\\managed\\node",
	required
)
assert(
	merged == "C:/managed/bin;C:/managed/node;C:\\legacy\\node;C:\\Windows",
	"PATH merge is not ordered and idempotent: " .. merged
)
assert(windows_adapter.merge_path(merged, required) == merged, "repeated PATH merge changed its output")

local failing_command, failing_arguments
if vim.fn.has("win32") == 1 then
	failing_command = "powershell.exe"
	failing_arguments = {
		"-NoProfile",
		"-NonInteractive",
		"-Command",
		"[Console]::Out.WriteLine('visible-stdout'); [Console]::Error.WriteLine('visible-stderr'); exit 7",
	}
else
	failing_command = "sh"
	failing_arguments = { "-c", "printf 'visible-stdout\\n'; printf 'visible-stderr\\n' >&2; exit 7" }
end
local ok, command_failure = pcall(commands.capture, failing_command, failing_arguments)
assert(not ok, "failing command unexpectedly succeeded")
assert(tostring(command_failure):find("visible-stdout", 1, true), "command failure omitted stdout")
assert(tostring(command_failure):find("visible-stderr", 1, true), "command failure omitted stderr")

local original_xdg_data_home = vim.env.XDG_DATA_HOME
vim.env.XDG_DATA_HOME = vim.fs.joinpath(vim.fn.tempname(), "data")
assert(
	linux_adapter.nvim_data() == vim.fs.joinpath(vim.env.XDG_DATA_HOME, "nvim"),
	"Unix Neovim data path ignored XDG_DATA_HOME"
)
vim.env.XDG_DATA_HOME = original_xdg_data_home

print("capability runtime tests passed")
