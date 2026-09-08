local M = {}

-- Capture before normalization, also for direct Lua entry. Preserve the first
-- capture across launcher/update children; retirement alone validates these hints.
if vim.env.WORKSTATION_SESSION_CAPTURED ~= "1" then
	vim.env.WORKSTATION_SESSION_RUNTIME_DIR = vim.env.XDG_RUNTIME_DIR or ""
	vim.env.WORKSTATION_SESSION_BUS_ADDRESS = vim.env.DBUS_SESSION_BUS_ADDRESS or ""
	vim.env.WORKSTATION_SESSION_CAPTURED = "1"
end
M.session = {
	runtime_dir = vim.env.WORKSTATION_SESSION_RUNTIME_DIR or "",
	bus_address = vim.env.WORKSTATION_SESSION_BUS_ADDRESS or "",
}
vim.env.DBUS_SESSION_BUS_ADDRESS = nil

-- Resolve before dispatch (including direct Lua bootstrap/diff/status). All
-- writable child roots belong to the target, never ambient XDG overrides.
M.home = vim.env.WORKSTATION_HOME or vim.env.HOME
assert(M.home and M.home:sub(1, 1) == "/", "target home must be absolute")
M.home = vim.fs.normalize(M.home)
M.local_dir = vim.fs.joinpath(M.home, ".local")
vim.env.HOME = M.home
vim.env.WORKSTATION_HOME = M.home
vim.env.USERPROFILE = M.home
vim.env.XDG_CONFIG_HOME = M.home .. "/.config"
vim.env.XDG_DATA_HOME = M.local_dir .. "/share"
vim.env.XDG_STATE_HOME = M.local_dir .. "/state"
vim.env.XDG_CACHE_HOME = M.home .. "/.cache"
vim.env.XDG_RUNTIME_DIR = M.local_dir .. "/state/workstation/run"
vim.env.WORKSTATION_CACHE = M.home .. "/.cache/workstation"
vim.env.TMPDIR = vim.env.XDG_RUNTIME_DIR .. "/tmp"
vim.fn.mkdir(vim.env.TMPDIR, "p", 448)
assert(vim.uv.fs_chmod(vim.env.XDG_RUNTIME_DIR, 448))

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
