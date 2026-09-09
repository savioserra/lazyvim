local paths = require("workstation.paths")

local M = {}

---Publish atomically without replacing user paths, even if a conflict appears
---between inspection and creation. Only the canonical matching link is owned.
function M.install(engine_root)
	local target = assert(vim.uv.fs_realpath(paths.join(engine_root, "bin", "workstation")))
	local directory = paths.join(paths.local_dir, "bin")
	local launcher = paths.join(directory, "workstation")
	vim.fn.mkdir(directory, "p")
	if vim.uv.fs_readlink(launcher) == target then
		return
	end
	assert(
		not vim.uv.fs_lstat(launcher),
		"refusing conflicting launcher at " .. launcher .. "; inspect and move it aside explicitly"
	)
	local ok, err = vim.uv.fs_symlink(target, launcher)
	assert(ok, "cannot publish launcher at " .. launcher .. ": " .. tostring(err))
end

function M.verify(engine_root)
	local target = assert(vim.uv.fs_realpath(paths.join(engine_root, "bin", "workstation")))
	local launcher = paths.join(paths.local_dir, "bin", "workstation")
	assert(
		vim.uv.fs_readlink(launcher) == target,
		"public launcher mismatch; inspect the path and run bootstrap: " .. launcher
	)
end

return M
