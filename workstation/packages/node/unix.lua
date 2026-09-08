local M = {}

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
