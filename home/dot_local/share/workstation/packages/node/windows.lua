local commands = require("workstation.commands")
local environment = require("workstation.host.windows_environment")

local M = {}

local function locations(context)
	local nvm = context.paths.join(context.paths.local_dir, "opt", "nvm-windows")
	local active = context.paths.join(nvm, "nodejs")
	return nvm, active, context.paths.join(active, "node.exe")
end

function M.configure(context)
	local nvm, active, node = locations(context)
	context.paths.write(
		context.paths.join(nvm, "settings.txt"),
		("root: %s\r\npath: %s\r\narch: 64\r\nproxy: none\r\n"):format(nvm, active)
	)
	local active_ok, active_version = pcall(commands.capture, node, { "--version" })
	if not active_ok or active_version ~= "v" .. context.versions.node then
		commands.execute(context.paths.join(nvm, "nvm.exe"), { "use", context.versions.node }, { timeout = 30000 })
	end
	local required = {
		context.paths.join(context.paths.local_dir, "bin"),
		vim.fs.dirname(context.platform.nvim),
		vim.fs.dirname(context.platform.tool("go")),
		nvm,
		active,
	}
	environment.write("Path", environment.merge_path(environment.read("Path"), required), true)
	environment.write("XDG_CONFIG_HOME", context.paths.join(context.paths.home, ".config"))
	environment.write("NVM_HOME", nvm)
	environment.write("NVM_SYMLINK", active)
end

function M.verify(context)
	local nvm, _, node = locations(context)
	assert(
		commands.capture(context.paths.join(nvm, "nvm.exe"), { "version" }) == context.versions.nvm_windows,
		"Unexpected nvm-windows version"
	)
	local persisted_path = environment.read("Path")
	local resolved =
		vim.split(commands.capture("where.exe", { "node.exe" }, { env = { PATH = persisted_path } }), "\n")[1]
	assert(
		environment.same_path(resolved, node),
		("Persisted user PATH resolves %s instead of %s"):format(resolved, node)
	)
end

return M
