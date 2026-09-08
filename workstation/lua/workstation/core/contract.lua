---@class Contribution
---@field id string
---@field requires? string[]
---@field supported_hosts? table<string, boolean>
---@field setup? fun(context: table)
---@field sync? fun(context: table)
---@field verify? fun(context: table)

local allowed_fields = {
	id = true,
	requires = true,
	supported_hosts = true,
	setup = true,
	sync = true,
	verify = true,
}

local lifecycle_fields = { "setup", "sync", "verify" }

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
