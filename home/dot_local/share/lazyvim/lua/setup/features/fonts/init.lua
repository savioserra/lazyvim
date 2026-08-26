local function backend(context)
	return require("setup.features.fonts." .. context.platform.name)
end

return {
	setup = function(context)
		backend(context).configure(context)
	end,
	verify = function(context)
		backend(context).verify(context)
	end,
}
