local commands = require("workstation.commands")
local paths = require("workstation.paths")

-- LuaJIT exposes varargs unpack as the global `unpack`; Lua 5.2+ as table.unpack.
local varargs_unpack = table.unpack or unpack

-- The chezmoi provisioner: the ONLY sanctioned way the engine materializes
-- home state. Chezmoi is a subordinate file provisioner invoked with explicit
-- --source/--destination; it is never driven by the user or by packages.

local M = {}

local script = debug.getinfo(1, "S").source:gsub("^@", "")
local module_path = vim.fs.normalize(script)
-- provisioner.lua lives at <repo>/workstation/lua/workstation/provisioner.lua
local engine_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(module_path)))

---Walk up from the engine root to the git root; fall back to the engine's
---parent directory (repo layout: the engine clone hosts chezmoi/ beside workstation/).
---@return string
function M.repo_root()
	local dir = engine_root
	for _ = 1, 16 do
		if vim.uv.fs_stat(paths.join(dir, ".git")) then
			return dir
		end
		local parent = vim.fs.dirname(dir)
		if parent == dir then
			break
		end
		dir = parent
	end
	return vim.fs.dirname(engine_root)
end

---@return string
function M.chezmoi_source()
	local source = paths.join(M.repo_root(), "chezmoi")
	assert(vim.uv.fs_stat(source), "chezmoi source not found beside the engine: " .. source)
	return source
end

local function chezmoi_executable()
	return paths.join(paths.local_dir, "opt", "chezmoi", "bin", "chezmoi")
end

function M.ensure_backend()
	local host = vim.uv.os_uname()
	local asset = host.sysname == "Linux" and host.machine == "x86_64" and "linux_x86_64"
		or host.sysname == "Darwin" and host.machine == "arm64" and "darwin_arm64"
	assert(asset, "unsupported backend platform: " .. host.sysname .. "/" .. host.machine)
	local versions = require("workstation.versions")
	require("workstation.provision").create(asset == "linux_x86_64" and "linux" or "darwin").archive({
		url = versions["chezmoi_" .. asset .. "_url"]:gsub("{V}", versions.chezmoi),
		sha256 = versions["chezmoi_" .. asset .. "_sha256"],
		format = "tar",
		inner_path = "chezmoi",
		dest = chezmoi_executable(),
	})
end

---Build the full chezmoi argv for an action against the engine's source tree.
---@param action string chezmoi action, e.g. "apply" or "diff"
---@param opts? { exclude?: string[], dry_run?: boolean, destination?: string }
---@return string[]
function M.argv(action, opts)
	opts = opts or {}
	local argv = {
		chezmoi_executable(),
		"--source",
		M.chezmoi_source(),
		"--destination",
		opts.destination or paths.home,
		action,
	}
	if opts.dry_run then
		table.insert(argv, "--dry-run")
	end
	for _, exclude in ipairs(opts.exclude or { "scripts" }) do
		table.insert(argv, "--exclude")
		table.insert(argv, exclude)
	end
	return argv
end

---Materialize home state (chezmoi apply with engine-provided source/destination).
function M.apply(opts)
	M.ensure_backend()
	local argv = M.argv("apply", opts)
	commands.execute(argv[1], { select(2, varargs_unpack(argv)) })
end

---Show pending home-state changes (chezmoi diff with engine-provided source/destination).
function M.diff(opts)
	M.ensure_backend()
	local argv = M.argv("diff", opts)
	commands.execute(argv[1], { select(2, varargs_unpack(argv)) })
end

return M
