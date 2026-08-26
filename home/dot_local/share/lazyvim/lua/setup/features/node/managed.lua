local M = {}

function M.bin(context)
	if context.platform.name == "win32" then
		return context.paths.join(context.paths.local_dir, "opt", "nvm-windows", "nodejs")
	end
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
	local suffix = ""
	if context.platform.name == "win32" then
		suffix = name == "node" and ".exe" or ".cmd"
	end
	return context.paths.join(M.bin(context), name .. suffix)
end

return M
