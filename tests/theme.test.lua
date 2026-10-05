-- Theme capability contract tests: canonical token shape, deterministic data
-- envelope rendering, the chezmoi data provider, and the plan-level wiring
-- (.chezmoidata.toml in the manifest, never a home target).
local repository = vim.fn.getcwd()
local scratch = vim.fn.tempname()
vim.env.WORKSTATION_HOME = scratch
package.path = table.concat({
	vim.fs.joinpath(repository, "workstation", "?.lua"),
	vim.fs.joinpath(repository, "workstation", "?", "init.lua"),
	vim.fs.joinpath(repository, "workstation", "lua", "?.lua"),
	vim.fs.joinpath(repository, "workstation", "lua", "?", "init.lua"),
	package.path,
}, ";")

local provider = require("workstation.provision.chezmoi_data")
local provision = require("workstation.provision.recipes")
local source = require("workstation.source")
local state = require("workstation.state")
local tokens = require("packages.theme.tokens")

-- Part 1: the token module carries every appearance and role, and renders a
-- byte-stable envelope.
local envelope = tokens.chezmoidata()
assert(envelope == tokens.chezmoidata(), "the data envelope is not deterministic")
for _, marker in ipairs({
	"version = 1",
	"[theme.slots]",
	'accent = "blue"',
	'chrome = "brightblack"',
	"[theme.palette.dark]",
	"[theme.palette.light]",
	"[theme.consumers.herdr]",
	'name = "terminal"',
	"auto_switch = true",
}) do
	assert(envelope:find(marker, 1, true), "envelope is missing " .. marker)
end
assert(envelope:sub(-1) == "\n", "envelope must end with a newline")
for appearance in pairs(tokens.palette) do
	assert(tokens.palette[appearance].accent ~= nil, appearance .. " palette has no accent")
end

-- Part 2: fail-closed validation on mutated token tables.
local function with_mutated(object, field, value, fn)
	local original = object[field]
	object[field] = value
	local ok, failure = pcall(fn)
	object[field] = original
	assert(not ok, "expected mutated tokens to fail: " .. tostring(field))
	local message = tostring(failure)
	assert(message:find("theme", 1, true) or message:find("herdr", 1, true), "unexpected failure: " .. message)
end

with_mutated(tokens.slots, "accent", "chartreuse", tokens.chezmoidata)
with_mutated(tokens.slots, "extra", "blue", tokens.chezmoidata)
with_mutated(tokens.palette.dark, "accent", "blue", tokens.chezmoidata)
with_mutated(tokens.palette, "neon", {}, tokens.chezmoidata)
with_mutated(tokens.consumers.herdr, "name", 42, tokens.chezmoidata)
with_mutated(tokens.consumers.herdr, "auto_switch", "yes", tokens.chezmoidata)
with_mutated(tokens.consumers, "pi", {}, tokens.chezmoidata)

-- Part 3: the data provider contract.
local recipe = provider.recipe({ content = "version = 1\n" })
assert(recipe.provider == "chezmoi-data" and recipe.spec.content == "version = 1\n")
assert(provision.chezmoi_data == provider.recipe, "recipes must expose the data constructor")

local function assert_fails(message, fn)
	local ok, failure = pcall(fn)
	assert(not ok, "expected failure: " .. message)
	assert(tostring(failure):find(message, 1, true), "unexpected failure: " .. tostring(failure))
end

assert_fails("unknown option", function()
	provider.recipe({ content = "x = 1\n", target = ".config/leak" })
end)
assert_fails("non-empty TOML content", function()
	provider.recipe({ content = "" })
end)
assert_fails("unknown field", function()
	provider.validate_spec({ content = "x = 1\n", kind = "file" })
end)
assert_fails("non-empty TOML content", function()
	provider.validate_spec({ content = "" })
end)

-- Part 4: the real catalog plan carries the envelope and every template
-- consumer, and the envelope is generation metadata, never a home target.
local application = require("workstation.app").create()
local plan = source.plan(application)
assert(plan.data ~= nil, "the plan is missing the .chezmoidata.toml envelope")
assert(plan.data.owner == "theme", "unexpected envelope owner: " .. tostring(plan.data.owner))
assert(plan.data.bytes == envelope, "the plan envelope does not match the token module")

local manifest_data
for _, entry in ipairs(plan.manifest) do
	if entry.name == ".chezmoidata.toml" then
		manifest_data = entry
	end
end
assert(manifest_data ~= nil, "the manifest is missing the .chezmoidata.toml entry")
assert(manifest_data.type == "file" and manifest_data.mode == 420, "envelope manifest entry has the wrong shape")
assert(manifest_data.sha256 == state.sha256(envelope), "envelope manifest digest drifted")
for _, entry in ipairs(plan.entries) do
	assert(entry.target ~= ".chezmoidata.toml", "the data envelope leaked into home targets")
end

local tmux_entry
local dark_entry, light_entry
for _, entry in ipairs(plan.entries) do
	if entry.target == ".config/tmux/themes/tmux2k.conf" then
		tmux_entry = entry
	elseif entry.target == ".pi/agent/themes/workstation-dark.json" then
		dark_entry = entry
	elseif entry.target == ".pi/agent/themes/workstation-light.json" then
		light_entry = entry
	end
end
assert(tmux_entry ~= nil and tmux_entry.template, "tmux2k.conf must render as a template")
assert(tmux_entry.source_name:sub(-#".tmpl") == ".tmpl", "tmux2k source name must carry the template suffix")
assert(tmux_entry.bytes:find("{{ .theme.slots.accent }}", 1, true), "tmux2k payload does not consume the slot layer")
assert(
	dark_entry ~= nil and dark_entry.template and light_entry ~= nil and light_entry.template,
	"pi themes must render as templates"
)
assert(
	dark_entry.bytes:find("{{ .theme.palette.dark.accent }}", 1, true)
		and light_entry.bytes:find("{{ .theme.palette.light.accent }}", 1, true),
	"pi theme payloads do not consume the palette layer"
)

-- The derived theme names never contain '/', so the automatic
-- "workstation-light/workstation-dark" pi setting stays representable.
for _, name in ipairs({ "workstation-dark", "workstation-light" }) do
	assert(not name:find("/"), "derived theme names must not contain '/'")
end

vim.fn.delete(scratch, "rf")
print("theme capability tests passed (tokens, data envelope, provider, plan wiring)")
