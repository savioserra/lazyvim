---@class CapabilityEnhancement
---@field extras_module? string
---@field plugin_module? string
---@field lazyvim_extras? string[]
---@field mason_packages? string[]
---@field language_cases? table[]
---@field formatter_cases? table[]

---@class Capability
---@field id string
---@field requires string[]
---@field supports fun(context: CapabilityContext): boolean
---@field enhancements table<string, CapabilityEnhancement[]>
---@field setup? fun(context: CapabilityContext)
---@field sync? fun(context: CapabilityContext)
---@field verify? fun(context: CapabilityContext)

local function validate_string_list(values, label)
	assert(type(values) == "table", label .. " must be a list")
	for index, value in ipairs(values) do
		assert(type(value) == "string" and value ~= "", ("%s[%d] must be a non-empty string"):format(label, index))
	end
end

local function validate_optional_string(value, label)
	assert(value == nil or (type(value) == "string" and value ~= ""), label .. " must be a non-empty string")
end

local function validate_behavior_cases(cases, fields, label)
	if cases == nil then
		return
	end
	assert(type(cases) == "table", label .. " must be a list")
	for index, case in ipairs(cases) do
		assert(type(case) == "table", ("%s[%d] must be a table"):format(label, index))
		for _, field in ipairs(fields) do
			assert(
				type(case[field]) == "string" and case[field] ~= "",
				("%s[%d].%s must be a non-empty string"):format(label, index, field)
			)
		end
	end
end

local function validate_enhancement(enhancement, label)
	assert(type(enhancement) == "table", label .. " must be a table")
	validate_optional_string(enhancement.extras_module, label .. ".extras_module")
	validate_optional_string(enhancement.plugin_module, label .. ".plugin_module")
	validate_string_list(enhancement.lazyvim_extras or {}, label .. ".lazyvim_extras")
	validate_string_list(enhancement.mason_packages or {}, label .. ".mason_packages")
	validate_behavior_cases(
		enhancement.language_cases,
		{ "language", "filename", "contents", "client" },
		label .. ".language_cases"
	)
	validate_behavior_cases(
		enhancement.formatter_cases,
		{ "language", "filename", "contents", "expected" },
		label .. ".formatter_cases"
	)
end

---@param definition Capability
---@return Capability
return function(definition)
	assert(type(definition) == "table", "capability definition must be a table")
	assert(type(definition.id) == "string" and definition.id ~= "", "capability requires a non-empty string id")
	definition.requires = definition.requires or {}
	validate_string_list(definition.requires, definition.id .. ".requires")
	definition.supports = definition.supports or function()
		return true
	end
	assert(type(definition.supports) == "function", definition.id .. ".supports must be a function")
	definition.enhancements = definition.enhancements or {}
	assert(type(definition.enhancements) == "table", definition.id .. ".enhancements must be a table")
	for target, enhancements in pairs(definition.enhancements) do
		assert(type(target) == "string" and type(enhancements) == "table", definition.id .. " has invalid enhancements")
		for index, enhancement in ipairs(enhancements) do
			validate_enhancement(enhancement, ("%s.enhancements.%s[%d]"):format(definition.id, target, index))
		end
	end
	for _, lifecycle in ipairs({ "setup", "sync", "verify" }) do
		assert(
			definition[lifecycle] == nil or type(definition[lifecycle]) == "function",
			definition.id .. "." .. lifecycle .. " must be a function"
		)
	end
	return definition
end
