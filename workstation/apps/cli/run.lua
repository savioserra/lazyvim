local script = debug.getinfo(1, "S").source:gsub("^@", "")
-- Resolve to an absolute path: packages derive verifier paths from their module
-- source, which must stay absolute regardless of the caller's cwd.
script = vim.uv.fs_realpath(script) or script
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(script))))
package.path = table.concat(
	{ root .. "/?.lua", root .. "/?/init.lua", root .. "/lua/?.lua", root .. "/lua/?/init.lua", package.path },
	";"
)

local commands = require("workstation.commands")
local paths = require("workstation.paths")
local provisioner = require("workstation.provisioner")

local command = assert(arg[1], "usage: workstation <apply|update|setup|sync|verify|diff|status|bootstrap>")
local known_commands = {
	apply = true,
	update = true,
	setup = true,
	sync = true,
	verify = true,
	diff = true,
	status = true,
	bootstrap = true,
}
assert(known_commands[command], "unknown command: " .. command)

if command == "sync" then
	vim.env.LAZYVIM_HEADLESS_SYNC = "1"
end

---Re-run a lifecycle through the public launcher so freshly pulled engine code
---takes effect for the remaining steps: update never runs new code in-process.
local function exec_via_launcher(step)
	local launcher = paths.join(root, "bin", "workstation")
	commands.execute(launcher, { step })
end

---versions.lua reads .node-version at require time, before apply exists it;
---refresh the pin in place once chezmoi has materialized the file.
local function refresh_node_version(context)
	local path = paths.join(context.paths.home, ".node-version")
	if context.paths.exists(path) then
		context.versions.node = vim.trim(context.paths.read(path))
	end
	context.platform.configure_runtime()
end

-- The shell has already installed the runtime before this handoff. Lua owns
-- the pinned file backend; bootstrap never delegates to an unpinned host tool.
if command == "bootstrap" then
	provisioner.ensure_backend()
	require("workstation.launcher").install(root)
	print("bootstrap complete.")
	return
end

-- diff is a pure chezmoi passthrough; it needs no application state.
if command == "diff" then
	provisioner.diff()
	return
end

local application = require("workstation.app").create()

if command == "status" then
	local platform = application.context.platform.name
	print(("workstation status (%s)"):format(platform))
	print(("  engine root  : %s"):format(root))
	print(("  repo root    : %s"):format(provisioner.repo_root()))
	print(("  destination  : %s"):format(application.context.paths.home))
	print(("  nvim runtime : %s"):format(vim.v.progpath))
	print(("  packages     : %d"):format(#application.packages))
	print("  graph order  :")
	for index, specification in ipairs(application.graph.ordered) do
		print(("    %d. %s"):format(index, specification.id))
	end
	print(("status complete (%s)."):format(platform))
	return
end

-- apply = engine retire phase -> chezmoi home state -> package setup.
if command == "apply" then
	require("workstation.retire").run(application.context)
	provisioner.apply()
	refresh_node_version(application.context)
	application.runner:run("setup")
	print(("apply complete (%s)."):format(application.context.platform.name))
	return
end

-- update pulls first, then re-execs each step so the new code is what runs.
if command == "update" then
	commands.execute("git", { "-C", provisioner.repo_root(), "pull", "--ff-only" })
	exec_via_launcher("bootstrap")
	exec_via_launcher("apply")
	exec_via_launcher("sync")
	exec_via_launcher("verify")
	print("update complete.")
	return
end

-- setup / sync / verify
if command == "verify" then
	require("workstation.launcher").verify(root)
end
application.runner:run(command)
print(("\n%s complete (%s)."):format(command, application.context.platform.name))
