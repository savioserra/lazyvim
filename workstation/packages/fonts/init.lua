local function backend(context)
	return require("packages.fonts." .. context.platform.name)
end

return function()
	return {
		id = "fonts",
		requires = { "foundation" },
		setup = function(context)
			backend(context).configure(context)
		end,
		verify = function(context)
			backend(context).verify(context)
		end,
	}
end
