---@class CapabilitySpec
---@field id string
---@field requires? string[]
---@field supported_hosts? table<string, boolean>

local function validate_string_list(values, label)
	assert(type(values) == "table", label .. " must be a list")
	for index, value in ipairs(values) do
		assert(type(value) == "string" and value ~= "", ("%s[%d] must be a non-empty string"):format(label, index))
	end
end

---@param specification CapabilitySpec
---@return CapabilitySpec
return function(specification)
	assert(type(specification) == "table", "capability specification must be a table")
	assert(type(specification.id) == "string" and specification.id ~= "", "capability requires a non-empty string id")
	validate_string_list(specification.requires or {}, specification.id .. ".requires")
	if specification.supported_hosts ~= nil then
		assert(type(specification.supported_hosts) == "table", specification.id .. ".supported_hosts must be a table")
		for host, supported in pairs(specification.supported_hosts) do
			assert(
				type(host) == "string" and type(supported) == "boolean",
				specification.id .. " has invalid host support"
			)
		end
	end
	return specification
end
