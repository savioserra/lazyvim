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

---@param catalog function[]
---@param environment? table
function M.from_catalog(catalog, environment)
	assert(type(catalog) == "table", "package catalog must be a list")
	local contributions, specifications, handlers, identities = {}, {}, {}, {}
	for index, factory in ipairs(catalog) do
		assert(type(factory) == "function", ("package catalog entry %d must be a factory"):format(index))
		local contribution = validate(factory(environment or {}))
		assert(not identities[contribution.id], "duplicate package identity: " .. contribution.id)
		identities[contribution.id] = true
		table.insert(contributions, contribution)
		table.insert(specifications, {
			id = contribution.id,
			requires = copy_list(contribution.requires),
			supported_hosts = copy_map(contribution.supported_hosts),
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
	}
end

return M
