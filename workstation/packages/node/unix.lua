local M = {}

function M.provision(context)
	local v = context.versions
	assert(
		type(v.node) == "string" and v.node:match("^%d+%.%d+%.%d+$"),
		"Missing or invalid managed Node pin; run workstation apply before setup"
	)
	local asset = context.platform.name == "darwin" and "darwin_arm64" or "linux_x86_64"
	local nvm = context.paths.join(context.paths.local_dir, "opt", "nvm")
	-- These trees also belong to nvm/npm. Overlay shipped members only: never
	-- prune aliases, other Node versions, or unrelated global npm packages.
	for _, tool in ipairs({
		{ "nvm_sh", nvm },
		{ "node", context.paths.join(nvm, "versions", "node", "v" .. v.node) },
	}) do
		local pin = tool[1] .. "_" .. asset
		context.provision.directory({
			url = v[pin .. "_url"]:gsub("{V}", v[tool[1]]),
			sha256 = v[pin .. "_sha256"],
			format = "tar",
			dest = tool[2],
			strip_components = 1,
			exact = false,
		})
	end
end

function M.configure(context)
	context.paths.write(
		context.paths.join(context.paths.local_dir, "opt", "nvm", "alias", "default"),
		context.versions.node .. "\n"
	)
end

function M.verify(context)
	local configured_version =
		vim.trim(context.paths.read(context.paths.join(context.paths.local_dir, "opt", "nvm", "alias", "default")))
	assert(
		configured_version == context.versions.node,
		("expected nvm default %s, got %s"):format(context.versions.node, configured_version)
	)
end

return M
