local repository = vim.fn.getcwd()
local root = vim.fs.joinpath(repository, "home", "dot_local", "share", "workstation")
package.path = table.concat({
	vim.fs.joinpath(root, "?.lua"),
	vim.fs.joinpath(root, "?", "init.lua"),
	vim.fs.joinpath(root, "lua", "?.lua"),
	vim.fs.joinpath(root, "lua", "?", "init.lua"),
	package.path,
}, ";")

local commands = require("workstation.commands")
local contract = require("workstation.core.contract")
local graph = require("workstation.core.graph")
local materialize = require("workstation.core.materialize")
local profile_module = require("packages.nvim.profile")
local runner_module = require("workstation.core.runner")

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
	return contract(vim.tbl_extend("force", { id = id, requires = requires or {} }, options or {}))
end

local profile_path = vim.fs.joinpath(repository, "home", "dot_config", "nvim", "lua", "languages", "profile.lua")
local profile = profile_module.validate(assert(loadfile(profile_path))())
local catalog = require("workstation.catalog")
local packages = materialize.from_catalog(catalog, { nvim_profile = profile })
local application = require("workstation.app")
assert(type(application.create) == "function", "workstation composition root did not load")

for _, name in ipairs({ "contract", "materialize", "graph", "runner" }) do
	local source = vim.fn.readfile(vim.fs.joinpath(root, "lua", "workstation", "core", name .. ".lua"))
	local contents = table.concat(source, "\n")
	assert(not contents:find('require("packages.', 1, true), "core imports a package: " .. name)
	assert(not contents:find("workstation.packages", 1, true), "core imports a legacy package namespace: " .. name)
	assert(not contents:find("workstation.catalog", 1, true), "core imports the catalog: " .. name)
	assert(not contents:find("vim.", 1, true), "core depends on the Neovim API: " .. name)
end

assert(
	vim.uv.fs_stat(vim.fs.joinpath(root, "lua", "workstation", "packages")) == nil,
	"legacy package contribution directory still exists"
)
for _, name in ipairs({
	"foundation",
	"fonts",
	"node",
	"pi",
	"pi-skills",
	"pi-subagents",
	"go",
	"subagents",
	"secrets",
	"nvim",
	"tmux",
	"pi-tmux-subagents",
}) do
	assert(
		vim.uv.fs_stat(vim.fs.joinpath(root, "packages", name, "init.lua")),
		"top-level package contribution is missing: " .. name
	)
end
for _, name in ipairs({ "pi-skills", "pi-subagents", "pi-tmux-subagents" }) do
	assert(
		vim.uv.fs_stat(vim.fs.joinpath(root, "packages", name, "verify.mjs")),
		"package verifier is missing: " .. name
	)
end
assert(#catalog == 12, "expected twelve explicitly registered packages")
for _, asset in ipairs({
	"dot_config/systemd/user/workstation-subagents.service.tmpl",
	"Library/LaunchAgents/com.workstation.subagents.plist.tmpl",
}) do
	local contents = assert(
		vim.uv.fs_stat(vim.fs.joinpath(repository, "home", asset)),
		"inactive service-manager asset missing: " .. asset
	)
	assert(contents.type == "file")
end
local subagents_package = assert(vim.fn.readfile(vim.fs.joinpath(root, "packages", "subagents", "init.lua")))
local subagents_package_source = table.concat(subagents_package, "\n")
for _, forbidden in ipairs({ "systemctl", "launchctl", "kickstart", "enable.*--now" }) do
	assert(
		not subagents_package_source:find(forbidden),
		"subagents lifecycle must never activate service assets: " .. forbidden
	)
end
local subagents_config = require("packages.subagents.config")
subagents_config.verify_inactive([[
[service]
enabled = false

[hosted_pi]
enabled = false

[remoting]
enabled = false
]])
assert(not pcall(
	subagents_config.verify_inactive,
	[[[service]
enabled=false
[hosted_pi]
enabled=false
[remoting]
enabled=true
]]
), "managed remoting gate must remain false")
assert_fails("[hosted_pi].enabled must be false", function()
	subagents_config.verify_inactive([[
[service]
enabled = false
[hosted_pi]
enabled = true
]])
end)
local managed_toml_corpus =
	vim.fs.joinpath(repository, "services", "subagents", "internal", "config", "testdata", "managed_toml_accepted")
local managed_toml_files = vim.fn.glob(vim.fs.joinpath(managed_toml_corpus, "*.toml"), false, true)
assert(#managed_toml_files > 0, "managed TOML acceptance corpus is empty")
for _, path in ipairs(managed_toml_files) do
	subagents_config.verify_inactive(table.concat(vim.fn.readfile(path), "\n"))
end
assert_fails("[service].enabled must be false", function()
	subagents_config.verify_inactive([[
[service]
enabled = true

[remoting]
enabled = false
]])
end)
assert_fails("[service].enabled must be false", function()
	subagents_config.verify_inactive([[
# [service]
# enabled = false

[remoting]
enabled = false
]])
end)
assert_fails("[service].enabled must be false", function()
	subagents_config.verify_inactive([[
[remoting]
enabled = false
]])
end)
assert_fails("multiline TOML strings are unsupported", function()
	subagents_config.verify_inactive([=[
note = """
[service]
enabled = false
"""
[service]
"enabled" = true
]=])
end)
for _, adversarial in ipairs({
	"schema_version = 01\n[service]\nenabled = false\n",
	"schema_version = -01\n[service]\nenabled = false\n",
	"schema_version = -0\n[service]\nenabled = false\n",
	"schema_version = +1\n[service]\nenabled = false\n",
	"schema_version = 9223372036854775808\n[service]\nenabled = false\n",
	"schema_version = -9223372036854775809\n[service]\nenabled = false\n",
	"schema_version\194\160= 1\n[service]\nenabled = false\n",
	"schema_version\v= 1\n[service]\nenabled = false\n",
	"service = 1\n[service]\nenabled = false\n",
	"[service]\nenabled = false\nservice = 1\n",
	"[service]\nenabled = false\n[service]\nenabled = true\n",
	"[service]\nenabled = false\nenabled = true\n",
	"['service']\nenabled = false\n",
	'[service]\n"enabled" = false\n',
	"[service]\nservice.enabled = false\n",
	"[service.child]\nenabled = false\n",
	"[[service]]\nenabled = false\n",
	"[service]\nenabled = { value = false }\n",
	"[service]\nenabled false\n",
	"[service]\nenabled = # false\n",
	"[service]\nenabled = 'false'\n",
	"[service]\nenabled = 1979-05-27T07:32:00Z\n",
	"[service]\nenabled = 0.0\n",
	"[service]\nenabled = false; enabled = true\n",
	"[service]\nenabled = false\n[remoting]\npeers = [1]\n",
}) do
	assert_fails("", function()
		subagents_config.verify_inactive(adversarial)
	end)
end
local subagents_metadata = require("packages.subagents.metadata")
subagents_metadata.verify(
	{ type = "directory", mode = 448, uid = 1000 },
	{ type = "file", mode = 384, uid = 1000 },
	1000
)
assert_fails("directory must be owned by the current user", function()
	subagents_metadata.verify(
		{ type = "directory", mode = 448, uid = 1001 },
		{ type = "file", mode = 384, uid = 1000 },
		1000
	)
end)
assert_fails("config must be owned by the current user", function()
	subagents_metadata.verify(
		{ type = "directory", mode = 448, uid = 1000 },
		{ type = "file", mode = 384, uid = 1001 },
		1000
	)
end)
assert(
	vim.uv.fs_stat(
		vim.fs.joinpath(
			repository,
			"home",
			"dot_config",
			"private_workstation",
			"private_subagents",
			"private_config.toml.tmpl"
		)
	),
	"owner-private subagents config source is missing"
)
assert(
	vim.uv.fs_stat(vim.fs.joinpath(repository, "home", "services")) == nil,
	"service source must not deploy into HOME"
)
assert(#packages.contributions == #catalog, "catalog and materialized package counts differ")
assert(
	vim.uv.fs_stat(vim.fs.joinpath(root, "lua", "setup", "capabilities")) == nil,
	"legacy capability catalog still exists"
)
assert(vim.uv.fs_stat(vim.fs.joinpath(root, "lua", "setup", "features")) == nil, "legacy feature catalog still exists")
for _, contribution in ipairs(packages.contributions) do
	assert(packages.handlers[contribution.id], "package is missing split lifecycle handlers: " .. contribution.id)
end

local function ids_for(host, specifications)
	return vim.tbl_map(function(item)
		return item.id
	end, graph.resolve(specifications or packages.specifications, host).ordered)
end

local windows = ids_for("win32") -- retained only as a native-Windows removal inventory during milestone 1
assert(not vim.list_contains(windows, "tmux"), "Windows must omit tmux")
assert(not vim.list_contains(windows, "subagents"), "native Windows must omit the subagents service")
for _, id in ipairs({ "nvim", "go", "secrets", "pi", "pi-skills", "pi-subagents" }) do
	assert_contains(windows, id)
end

local linux = ids_for("linux")
for _, id in ipairs({ "tmux", "secrets", "pi", "pi-skills", "pi-subagents", "subagents" }) do
	assert_contains(linux, id)
end
local expected_linux = {
	"foundation",
	"fonts",
	"node",
	"pi",
	"pi-skills",
	"pi-subagents",
	"go",
	"subagents",
	"secrets",
	"nvim",
	"tmux",
	"pi-tmux-subagents",
}
assert(vim.deep_equal(linux, expected_linux), "Linux package graph order changed")
assert(vim.deep_equal(ids_for("darwin"), expected_linux), "macOS package graph order differs from Linux")
local expected_windows = {
	"foundation",
	"fonts",
	"node",
	"pi",
	"pi-skills",
	"pi-subagents",
	"go",
	"secrets",
	"nvim",
}
assert(vim.deep_equal(windows, expected_windows), "Windows graph changed")

local function index_of(values, expected)
	return assert(
		vim.iter(values):enumerate():find(function(_, id)
			return id == expected
		end),
		"missing package " .. expected
	)
end
assert(index_of(linux, "node") < index_of(linux, "pi"), "node must run before pi")
assert(index_of(linux, "pi") < index_of(linux, "pi-skills"), "pi must run before pi-skills")
assert(index_of(linux, "pi") < index_of(linux, "pi-subagents"), "pi must run before pi-subagents")
assert(index_of(linux, "pi-skills") < index_of(linux, "pi-subagents"), "pi-skills must run before pi-subagents")
assert(index_of(linux, "go") < index_of(linux, "subagents"), "managed Go must precede the subagents source spike")
assert(index_of(linux, "foundation") < index_of(linux, "secrets"), "foundation must run before secrets")
assert(index_of(linux, "foundation") < index_of(linux, "tmux"), "foundation must run before tmux")
assert(
	index_of(linux, "pi-subagents") < index_of(linux, "pi-tmux-subagents"),
	"pi-subagents must run before its tmux observer"
)
assert(index_of(linux, "tmux") < index_of(linux, "pi-tmux-subagents"), "tmux must run before its Pi observer")
assert(not vim.list_contains(windows, "pi-tmux-subagents"), "Windows must omit the tmux Pi observer")

local prerequisites = profile_module.required_capabilities(profile)
assert_contains(prerequisites, "node")
assert_contains(prerequisites, "go")
for _, prerequisite in ipairs({ "foundation", "node", "go" }) do
	assert(index_of(linux, prerequisite) < index_of(linux, "nvim"), prerequisite .. " must run before Neovim")
end

assert_fails("duplicate package identity", function()
	materialize.from_catalog({
		function()
			return { id = "same" }
		end,
		function()
			return { id = "same" }
		end,
	})
end)
assert_fails("requires a non-empty string id", function()
	materialize.from_catalog({
		function()
			return { verify = function() end }
		end,
	})
end)
assert_fails("catalog entry 1 must be a factory", function()
	materialize.from_catalog({ { id = "not-a-factory" } })
end)
assert_fails("invalid lifecycle handler setup", function()
	contract({ id = "invalid", setup = "not-a-function" })
end)
assert_fails("unknown contribution field", function()
	contract({ id = "invalid", handlers = {} })
end)
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
local runner = runner_module.new(test_graph, {
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
assert_fails("missing lifecycle handlers for package first", function()
	runner_module.new(test_graph, { second = {} }, {})
end)
assert_fails("unknown lifecycle", function()
	runner:run("deploy")
end)

package.loaded["workstation.platforms.linux"] = nil
package.loaded["workstation.platforms.macos"] = nil
local linux_adapter = require("workstation.platforms.linux")
local macos_adapter = require("workstation.platforms.macos")
assert(not rawequal(linux_adapter, macos_adapter), "platform adapters must be independent tables")
assert(linux_adapter.name == "linux", "loading macOS must not mutate Linux")
assert(macos_adapter.name == "darwin", "macOS adapter has the wrong name")

local windows_environment = require("workstation.host.windows_environment")
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

print("workstation package runtime tests passed")
