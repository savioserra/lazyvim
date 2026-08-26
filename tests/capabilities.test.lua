local root = vim.fs.joinpath(vim.fn.getcwd(), "home", "dot_local", "share", "lazyvim")
package.path = table.concat({
	vim.fs.joinpath(root, "lua", "?.lua"),
	vim.fs.joinpath(root, "lua", "?", "init.lua"),
	package.path,
}, ";")

local commands = require("setup.commands")
local define = require("setup.runtime.contract")
local graph = require("setup.runtime.graph")
local profile_module = require("setup.features.nvim.profile")

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
	return define(vim.tbl_extend("force", { id = id, requires = requires or {} }, options or {}))
end

local function ids_for(host, specifications)
	return vim.tbl_map(function(item)
		return item.id
	end, graph.resolve(specifications or require("setup.capabilities.catalog"), host).ordered)
end

local windows = ids_for("win32")
assert(not vim.list_contains(windows, "tmux"), "Windows must omit tmux")
assert_contains(windows, "nvim")
assert_contains(windows, "go")

local linux = ids_for("linux")
assert_contains(linux, "tmux")
local foundation_index = vim.iter(linux):enumerate():find(function(_, id)
	return id == "foundation"
end)
local tmux_index = vim.iter(linux):enumerate():find(function(_, id)
	return id == "tmux"
end)
assert(foundation_index < tmux_index, "foundation must run before tmux")

local profile_path = vim.fs.joinpath(vim.fn.getcwd(), "home", "dot_config", "nvim", "lua", "languages", "profile.lua")
local profile = profile_module.validate(assert(loadfile(profile_path))())
local prerequisites = profile_module.required_capabilities(profile)
assert_contains(prerequisites, "node")
assert_contains(prerequisites, "go")

local application = require("setup.app")
local composed = ids_for("linux", application.specifications_for(profile))
local nvim_index = vim.iter(composed):enumerate():find(function(_, id)
	return id == "nvim"
end)
for _, prerequisite in ipairs({ "foundation", "node", "go" }) do
	local index = vim.iter(composed):enumerate():find(function(_, id)
		return id == prerequisite
	end)
	assert(index < nvim_index, prerequisite .. " must run before the composed Neovim capability")
end

assert_fails("duplicate capability", function()
	graph.resolve({ capability("same"), capability("same") }, "test")
end)
assert_fails("requires unknown capability", function()
	graph.resolve({ capability("dependent", { "missing" }) }, "test")
end)
assert_fails("dependency cycle", function()
	graph.resolve({ capability("a", { "b" }), capability("b", { "a" }) }, "test")
end)
assert_fails("requires unsupported capability", function()
	graph.resolve({
		capability("unsupported", nil, { supported_hosts = { other = true } }),
		capability("dependent", { "unsupported" }),
	}, "test")
end)
assert_fails("requires[1] must be a non-empty string", function()
	capability("invalid", { 42 })
end)
assert_fails("language_cases[1].client must be a non-empty string", function()
	profile_module.validate({
		{
			id = "invalid",
			language_cases = { { language = "lua", filename = "test.lua", contents = "return true\n" } },
		},
	})
end)

local lifecycle_order = {}
local test_graph = graph.resolve({ capability("first"), capability("second", { "first" }) }, "test")
local runner = require("setup.runtime.runner").new(test_graph, {
	first = {
		verify = function()
			table.insert(lifecycle_order, "first")
		end,
	},
	second = {
		verify = function()
			table.insert(lifecycle_order, "second")
		end,
	},
}, {})
runner:run("verify")
assert(vim.deep_equal(lifecycle_order, { "first", "second" }), "runner ignored dependency order")

package.loaded["setup.platforms.linux"] = nil
package.loaded["setup.platforms.macos"] = nil
local linux_adapter = require("setup.platforms.linux")
local macos_adapter = require("setup.platforms.macos")
assert(not rawequal(linux_adapter, macos_adapter), "platform adapters must be independent tables")
assert(linux_adapter.name == "linux", "loading macOS must not mutate Linux")
assert(macos_adapter.name == "darwin", "macOS adapter has the wrong name")

local windows_environment = require("setup.host.windows_environment")
local required = { "C:/managed/bin", "C:/managed/node" }
local merged = windows_environment.merge_path(
	"C:\\legacy\\node;C:\\managed\\bin;C:/managed/bin/;C:\\Windows;C:\\managed\\node",
	required
)
assert(
	merged == "C:/managed/bin;C:/managed/node;C:\\legacy\\node;C:\\Windows",
	"PATH merge is not ordered and idempotent: " .. merged
)
assert(windows_environment.merge_path(merged, required) == merged, "repeated PATH merge changed its output")

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
