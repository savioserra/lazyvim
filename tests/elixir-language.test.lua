-- Elixir language capability contract tests: package shape, the profile
-- intent validated through the nvim-owned validator, the deployed plugin
-- module's ownership markers, and the Mason-package vs LSP-client pairing
-- that would otherwise rot silently (Mason ships "elixir-ls", the attached
-- client is "elixirls").
local repository = vim.fn.getcwd()
package.path = table.concat({
	vim.fs.joinpath(repository, "workstation", "?.lua"),
	vim.fs.joinpath(repository, "workstation", "?", "init.lua"),
	vim.fs.joinpath(repository, "workstation", "lua", "?.lua"),
	vim.fs.joinpath(repository, "workstation", "lua", "?", "init.lua"),
	package.path,
}, ";")

local profile_module = require("packages.nvim.profile")
-- Loading the factory runs the real profile validator over the intent.
local specification = require("packages.elixir")()
local intent = specification.contributes[1].spec.entry

local function assert_fails(message, fn)
	local ok, err = pcall(fn)
	assert(
		not ok and tostring(err):find(message, 1, true),
		"expected failure matching '" .. message .. "', got " .. (ok and "success" or tostring(err))
	)
end

-- Part 1: package shape — a pure nvim-dependent language leaf contributing
-- exactly its profile intent and its deployed plugin module.
assert(specification.id == "elixir", "elixir capability id drifted")
assert(vim.deep_equal(specification.requires, { "nvim" }), "elixir requires drifted")
assert(#specification.contributes == 2, "elixir must contribute exactly the profile intent and the plugin module")
assert(
	specification.contributes[1].spec.order == 25,
	"elixir profile order must sit between typescript (20) and standard (30)"
)
assert(
	specification.contributes[2].spec.target == ".config/nvim/lua/languages/plugins/elixir.lua",
	"plugin module target drifted"
)
assert(specification.contributes[2].spec.asset == "files/languages/plugins/elixir.lua", "plugin module asset drifted")
assert(specification.contributes[2].spec.kind == "file", "plugin module must deploy as a plain file")

-- Part 2: intent contract. Mason package name and lspconfig client name are
-- deliberately different; the language case attaches by client name while
-- Mason owns the binary, so pin the pairing to catch silent drift.
assert(intent.id == "elixir", "elixir intent id drifted")
assert(intent.plugin_module == "languages.plugins.elixir", "elixir plugin module drifted")
assert(vim.deep_equal(intent.lazyvim_extras, { "lazyvim.plugins.extras.lang.elixir" }), "elixir lazyvim extras drifted")
assert(vim.deep_equal(intent.mason_packages, { "elixir-ls" }), "elixir mason packages drifted")
assert(intent.language_cases[1].client == "elixirls", "language case must attach to the elixirls client")
assert(
	intent.mason_packages[1] == "elixir-ls" and intent.language_cases[1].client == "elixirls",
	"Mason ships elixir-ls but the attached LSP client is elixirls"
)
local formatter_case = intent.formatter_cases[1]
assert(
	formatter_case.project_files["mix.exs"]:find("use Mix%.Project", 1, false),
	"the formatter case must run inside a mix project: conform chdirs to the mix.exs root"
)
assert(
	formatter_case.expected:find("  def answer do", 1, true),
	"expected output must carry canonical mix format two-space indentation"
)

-- Part 3: the deployed plugin module keeps its ownership markers — conform
-- owns autoformatting via mix format, and ElixirLS's slow optional subsystems
-- stay off.
local module_source = table.concat(
	vim.fn.readfile(
		vim.fs.joinpath(repository, "workstation", "packages", "elixir", "files", "languages", "plugins", "elixir.lua")
	),
	"\n"
)
for _, marker in ipairs({
	"dialyzerEnabled = false",
	"fetchDeps = false",
	'formatters_by_ft.elixir = { "mix" }',
}) do
	assert(module_source:find(marker, 1, true), "deployed plugin module is missing " .. marker)
end

-- Part 4: the shared validator rejects malformed language intents with the
-- same strictness nvim applies to its own profiles.
assert_fails("must be a non-empty string", function()
	profile_module.recipe({ order = 25, entry = { id = "elixir", mason_packages = { "" } } })
end)
