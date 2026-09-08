local M = {}

function M.bin(context)
	return context.paths.join(
		context.paths.local_dir,
		"opt",
		"nvm",
		"versions",
		"node",
		"v" .. context.versions.node,
		"bin"
	)
end

function M.executable(context, name)
	return context.paths.join(M.bin(context), name)
end

return M
