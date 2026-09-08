local M = {}

-- WORKSTATION_HOME wins: the engine CLI uses it for scratch-home testing.
-- CHEZMOI_DESTDIR follows: legacy compatibility while chezmoi scripts still exist.
M.home = vim.env.WORKSTATION_HOME or vim.env.CHEZMOI_DESTDIR or vim.env.HOME or vim.env.USERPROFILE
assert(M.home and M.home ~= "", "unable to determine target home")
M.home = vim.fs.normalize(M.home)
M.local_dir = vim.fs.joinpath(M.home, ".local")

function M.join(...)
	return vim.fs.joinpath(...)
end

function M.read(path)
	local file = assert(io.open(path, "rb"))
	local contents = file:read("*a")
	file:close()
	return contents
end

function M.write(path, contents)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	local file = assert(io.open(path, "wb"))
	assert(file:write(contents))
	file:close()
end

function M.exists(path)
	return vim.uv.fs_stat(path) ~= nil
end

return M
