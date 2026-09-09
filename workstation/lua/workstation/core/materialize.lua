local validate = require("workstation.core.contract")

local M = {}

local function copy_list(values)
	local copy = {}
	for index, value in ipairs(values or {}) do
		copy[index] = value
	end
	return copy
end

local function copy_map(values)
	if values == nil then
		return nil
	end
	local copy = {}
	for key, value in pairs(values) do
		copy[key] = value
	end
	return copy
end

-- Copy recipe records without merging: each envelope is reproduced with a
-- copied spec so later mutation of a package's declared table cannot silently
-- alter the materialized desired state. No deep merging ever happens.
local function copy_recipes(values)
	if values == nil then
		return nil
	end
	local copy = {}
	for index, recipe in ipairs(values) do
		copy[index] = { provider = recipe.provider, spec = copy_map(recipe.spec) }
	end
	return copy
end

-- Resolve the directory a package factory was declared from, so recipe
-- assets stay confined to their owning package. Factories from outside the
-- packages tree (tests, fixtures) have no root and cannot declare assets.
-- Core stays free of Neovim APIs, so this is plain string path handling over
-- the absolute script paths the launcher puts on package.path.
local function factory_root(factory)
	local source = assert(debug.getinfo(factory, "S").source, "factory is missing source information")
	source = source:gsub("^@", "")
	local package_root = source:match("^(.*)/packages/[^/]+/init%.lua$")
	return package_root and package_root .. "/packages/" .. source:match("/packages/([^/]+)/init%.lua$") or nil
end

---@param catalog function[]
---@param environment? table
function M.from_catalog(catalog, environment)
	assert(type(catalog) == "table", "package catalog must be a list")
	local contributions, specifications, handlers, identities, roots = {}, {}, {}, {}, {}
	for index, factory in ipairs(catalog) do
		assert(type(factory) == "function", ("package catalog entry %d must be a factory"):format(index))
		local contribution = validate(factory(environment or {}))
		assert(not identities[contribution.id], "duplicate package identity: " .. contribution.id)
		identities[contribution.id] = true
		roots[contribution.id] = factory_root(factory)
		table.insert(contributions, contribution)
		table.insert(specifications, {
			id = contribution.id,
			requires = copy_list(contribution.requires),
			supported_hosts = copy_map(contribution.supported_hosts),
			contributes = copy_recipes(contribution.contributes),
		})
		handlers[contribution.id] = {
			setup = contribution.setup,
			sync = contribution.sync,
			verify = contribution.verify,
		}
	end
	return {
		contributions = contributions,
		specifications = specifications,
		handlers = handlers,
		roots = roots,
	}
end

return M
