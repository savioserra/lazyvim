---@class ContributionRecipe
---@field provider string
---@field spec table

---@class Contribution
---@field id string
---@field requires? string[]
---@field supported_hosts? table<string, boolean>
---@field contributes? ContributionRecipe[]
---@field setup? fun(context: table)
---@field sync? fun(context: table)
---@field verify? fun(context: table)

local allowed_fields = {
	id = true,
	requires = true,
	supported_hosts = true,
	contributes = true,
	setup = true,
	sync = true,
	verify = true,
}

local lifecycle_fields = { "setup", "sync", "verify" }

-- Core validates only the generic envelope shape: a dense array of records
-- naming a registered provider ID plus an opaque option table. Domain
-- validation belongs to the explicitly registered providers, never to core.
local function validate_recipes(contribution)
	assert(type(contribution.contributes) == "table", contribution.id .. ".contributes must be a list")
	local total = 0
	for _ in pairs(contribution.contributes) do
		total = total + 1
	end
	assert(#contribution.contributes == total, contribution.id .. ".contributes must be a dense array")
	for index, recipe in ipairs(contribution.contributes) do
		local label = ("%s.contributes[%d]"):format(contribution.id, index)
		assert(type(recipe) == "table", label .. " must be a table")
		local count = 0
		for field in pairs(recipe) do
			count = count + 1
			assert(field == "provider" or field == "spec", label .. " has unknown envelope field " .. tostring(field))
		end
		assert(
			type(recipe.provider) == "string" and recipe.provider ~= "",
			label .. ".provider must be a non-empty string"
		)
		assert(type(recipe.spec) == "table", label .. ".spec must be a table")
		assert(count == 2, label .. " requires exactly provider and spec")
	end
end

local function validate_string_list(values, label)
	assert(type(values) == "table", label .. " must be a list")
	for index, value in ipairs(values) do
		assert(type(value) == "string" and value ~= "", ("%s[%d] must be a non-empty string"):format(label, index))
	end
end

---@param contribution Contribution
---@return Contribution
return function(contribution)
	assert(type(contribution) == "table", "package contribution must be a table")
	assert(
		type(contribution.id) == "string" and contribution.id ~= "",
		"package contribution requires a non-empty string id"
	)
	for field in pairs(contribution) do
		assert(allowed_fields[field], contribution.id .. " has unknown contribution field " .. tostring(field))
	end
	validate_string_list(contribution.requires or {}, contribution.id .. ".requires")
	if contribution.contributes ~= nil then
		validate_recipes(contribution)
	end
	if contribution.supported_hosts ~= nil then
		assert(type(contribution.supported_hosts) == "table", contribution.id .. ".supported_hosts must be a table")
		for host, supported in pairs(contribution.supported_hosts) do
			assert(
				type(host) == "string" and host ~= "" and type(supported) == "boolean",
				contribution.id .. " has invalid host support"
			)
		end
	end
	for _, lifecycle in ipairs(lifecycle_fields) do
		assert(
			contribution[lifecycle] == nil or type(contribution[lifecycle]) == "function",
			contribution.id .. " has invalid lifecycle handler " .. lifecycle
		)
	end
	return contribution
end
