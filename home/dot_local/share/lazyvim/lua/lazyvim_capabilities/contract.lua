return function(definition)
	assert(type(definition) == "table" and type(definition.id) == "string", "capability requires a string id")
	definition.requires = definition.requires or {}
	definition.supports = definition.supports or function()
		return true
	end
	definition.enhancements = definition.enhancements or {}
	return definition
end
