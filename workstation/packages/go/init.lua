local commands = require("workstation.commands")

return function()
	return {
		id = "go",
		requires = { "foundation" },
		setup = function(context)
			local v = context.versions
			local asset = context.platform.name == "darwin" and "darwin_arm64" or "linux_x86_64"
			context.provision.directory({
				url = v["go_" .. asset .. "_url"]:gsub("{V}", v.go),
				sha256 = v["go_" .. asset .. "_sha256"],
				format = "tar",
				dest = context.paths.join(context.paths.local_dir, "opt", "go"),
				strip_components = 1,
				exact = true,
			})
		end,
		verify = function(context)
			local actual = commands.capture(context.platform.tool("go"), { "version" })
			assert(vim.startswith(actual, "go version go" .. context.versions.go), "Unexpected Go version: " .. actual)
		end,
	}
end
