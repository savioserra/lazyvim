local function backend(context)
	return require("packages.fonts." .. context.platform.name)
end

return function()
	return {
		id = "fonts",
		requires = { "foundation" },
		setup = function(context)
			local v = context.versions
			local asset = context.platform.name == "darwin" and "darwin_arm64" or "linux_x86_64"
			context.provision.directory({
				url = v["font_" .. asset .. "_url"]:gsub("{V}", v.font),
				sha256 = v["font_" .. asset .. "_sha256"],
				format = "tar",
				dest = backend(context).directory(context),
				strip_components = 0,
				exact = true,
			})
			backend(context).configure(context)
		end,
		verify = function(context)
			backend(context).verify(context)
		end,
	}
end
