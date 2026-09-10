local repository = vim.fn.getcwd()
local root = vim.fs.joinpath(repository, "workstation")
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
local paths = require("workstation.paths")
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

local application_module = require("workstation.app")
local catalog = require("workstation.catalog")
assert(type(application_module.create) == "function", "workstation composition root did not load")
local application = application_module.create()
local plan = require("workstation.source").plan(application)
local packages = materialize.from_catalog(catalog, { context = application.context })
local profile = application.context.nvim_profile
assert(profile ~= nil and profile == plan.profile, "composed profile was not attached to the context")
local catalog_count = #catalog

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
	"pi-web-access",
	"pi-ntfy-notifier",
	"go",
	"herdr",
	"herdr-pi",
	"secrets",
	"nvim",
	"typescript",
	"tmux",
}) do
	assert(
		vim.uv.fs_stat(vim.fs.joinpath(root, "packages", name, "init.lua")),
		"top-level package contribution is missing: " .. name
	)
end
-- pi-ntfy-notifier is source-managed: its node test suite is executed directly
-- by its Lua verify step, so it has no separate verify.mjs.
for _, name in ipairs({ "pi-skills", "pi-subagents", "pi-web-access", "herdr-pi" }) do
	assert(
		vim.uv.fs_stat(vim.fs.joinpath(root, "packages", name, "verify.mjs")),
		"package verifier is missing: " .. name
	)
end
assert(catalog_count == 15, "expected fifteen explicitly registered packages")
-- The centralized checked-in chezmoi tree is fully retired: every payload
-- item lives with its owning capability and no legacy adapter remains.
assert(vim.uv.fs_stat(vim.fs.joinpath(repository, "chezmoi")) == nil, "centralized chezmoi tree still exists")
assert(
	vim.uv.fs_stat(vim.fs.joinpath(root, "packages", "migration-source")) == nil,
	"temporary migration adapter still exists"
)
-- Repository instructions cannot deploy: no recipe declares an AGENTS target.
for _, entry in ipairs(plan.entries) do
	assert(not entry.target:find("AGENTS.md", 1, true), "instructions leaked into the plan: " .. entry.target)
end
assert(#packages.contributions == catalog_count, "catalog and materialized package counts differ")
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

local linux = ids_for("linux")
for _, id in ipairs({ "tmux", "secrets", "pi", "pi-skills", "pi-subagents", "pi-web-access", "pi-ntfy-notifier" }) do
	assert_contains(linux, id)
end
local expected_linux = {
	"foundation",
	"fonts",
	"node",
	"pi",
	"pi-skills",
	"pi-subagents",
	"pi-web-access",
	"pi-ntfy-notifier",
	"go",
	"herdr",
	"herdr-pi",
	"secrets",
	"nvim",
	"typescript",
	"tmux",
}
assert(vim.deep_equal(linux, expected_linux), "Linux package graph order changed")
assert(vim.deep_equal(ids_for("darwin"), expected_linux), "macOS package graph order differs from Linux")

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
assert(index_of(linux, "pi") < index_of(linux, "pi-web-access"), "pi must run before pi-web-access")
assert(index_of(linux, "foundation") < index_of(linux, "secrets"), "foundation must run before secrets")
assert(index_of(linux, "foundation") < index_of(linux, "tmux"), "foundation must run before tmux")

-- nvim's dependencies are declared, not inferred from the deployed profile;
-- typescript depends on node+nvim and never the other way around.
local nvim_specification
for _, specification in ipairs(application.graph.ordered) do
	if specification.id == "nvim" then
		nvim_specification = specification
	end
end
assert(vim.deep_equal(nvim_specification.requires, { "foundation", "node", "go" }), "nvim requires drifted")
local typescript_specification
for _, specification in ipairs(application.graph.ordered) do
	if specification.id == "typescript" then
		typescript_specification = specification
	end
end
assert(vim.deep_equal(typescript_specification.requires, { "node", "nvim" }), "typescript requires drifted")
local herdr_specification
for _, specification in ipairs(application.graph.ordered) do
	if specification.id == "herdr" then
		herdr_specification = specification
	end
end
assert(vim.deep_equal(herdr_specification.requires, { "foundation" }), "herdr requires drifted")
local herdr_pi_specification
for _, specification in ipairs(application.graph.ordered) do
	if specification.id == "herdr-pi" then
		herdr_pi_specification = specification
	end
end
assert(vim.deep_equal(herdr_pi_specification.requires, { "pi", "herdr", "pi-subagents" }), "herdr-pi requires drifted")
for _, prerequisite in ipairs({ "pi", "herdr", "pi-subagents" }) do
	assert(index_of(linux, prerequisite) < index_of(linux, "herdr-pi"), prerequisite .. " must run before herdr-pi")
end
-- Herdr is runtime-optional: neither Pi nor the subagent engine requires it.
for _, id in ipairs({ "pi", "pi-skills", "pi-subagents", "pi-web-access", "pi-ntfy-notifier" }) do
	assert(index_of(linux, "herdr") > index_of(linux, id), "herdr must not gate " .. id)
end
for _, prerequisite in ipairs({ "foundation", "node", "go" }) do
	assert(index_of(linux, prerequisite) < index_of(linux, "nvim"), prerequisite .. " must run before Neovim")
end
assert(index_of(linux, "nvim") < index_of(linux, "typescript"), "nvim must run before typescript")
-- The composed profile preserves the explicit Go, TypeScript, standard order.
assert(#profile == 3 and profile[1].id == "go" and profile[2].id == "typescript" and profile[3].id == "standard")

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

local host_dir = vim.fs.joinpath(root, "lua", "workstation", "host")
if vim.uv.fs_stat(host_dir) then
	for _, name in ipairs(vim.fn.readdir(host_dir)) do
		assert(not name:match("^win"), "windows host helper still present: " .. name)
	end
end
for _, name in ipairs({ "fonts", "node", "foundation", "secrets" }) do
	local package_dir = vim.fs.joinpath(root, "packages", name)
	for _, entry in ipairs(vim.fn.readdir(package_dir)) do
		assert(not entry:match("^win"), "windows backend still present: " .. name .. "/" .. entry)
	end
end

local failing_command, failing_arguments
failing_command = "sh"
failing_arguments = { "-c", "printf 'visible-stdout\\n'; printf 'visible-stderr\\n' >&2; exit 7" }
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

-- CLI smoke: `workstation status` must exit 0 against a scratch destination
-- home (the public surface has to work pre-apply, before any file exists).
-- nvim's io.popen cannot report child exit codes, so the smoke runs through a
-- shell wrapper that records the status and output in temp files.
local scratch_home = vim.fn.tempname()
vim.fn.mkdir(scratch_home, "p")
local node_version_file = io.open(vim.fs.joinpath(scratch_home, ".node-version"), "w")
assert(node_version_file, "unable to write scratch .node-version")
node_version_file:write("24.19.0\n")
node_version_file:close()
local cli_path = vim.fs.joinpath(repository, "workstation", "apps", "cli", "run.lua")
local status_output_file = vim.fn.tempname()
local status_code_file = vim.fn.tempname()
local status_command = table.concat({
	("WORKSTATION_HOME=%s"):format(vim.fn.shellescape(scratch_home)),
	vim.fn.shellescape(vim.v.progpath),
	"-l",
	vim.fn.shellescape(cli_path),
	"status",
	("> %s 2>&1"):format(vim.fn.shellescape(status_output_file)),
	("; printf '%%s' $? > %s"):format(vim.fn.shellescape(status_code_file)),
}, " ")
assert(os.execute(status_command), "workstation status smoke could not execute")
local status_code = vim.trim(paths.read(status_code_file))
local status_output = paths.read(status_output_file)
assert(status_code == "0", "workstation status failed in scratch home:\n" .. status_output)
assert(status_output:find("status complete", 1, true), "workstation status produced no summary:\n" .. status_output)
vim.fn.delete(scratch_home, "rf")
vim.fn.delete(status_output_file)
vim.fn.delete(status_code_file)

print("workstation package runtime tests passed")
