local repository = vim.fn.getcwd()
local host_commands = {}
for _, name in ipairs({ "sh", "dirname", "readlink", "uname", "mkdir", "chmod" }) do
	host_commands[name] = assert(vim.fn.exepath(name))
	assert(host_commands[name] ~= "", "missing fixture prerequisite: " .. name)
end
local scratch = vim.fn.tempname()
vim.env.WORKSTATION_HOME = scratch .. "/target"
for _, key in ipairs({
	"XDG_CONFIG_HOME",
	"XDG_DATA_HOME",
	"XDG_STATE_HOME",
	"XDG_CACHE_HOME",
	"XDG_RUNTIME_DIR",
	"WORKSTATION_CACHE",
}) do
	vim.env[key] = scratch .. "/ambient/" .. key
end
-- A bound, non-listening scratch socket models rendezvous metadata only.
-- No test connects to it or to any live service endpoint.
local session_runtime = scratch .. "/session"
vim.fn.mkdir(session_runtime, "p", 448)
assert(vim.uv.fs_chmod(session_runtime, 448))
local session_bus = assert(vim.uv.new_pipe(false))
assert(session_bus:bind(session_runtime .. "/bus"))
vim.env.XDG_RUNTIME_DIR = session_runtime
vim.env.DBUS_SESSION_BUS_ADDRESS = nil
vim.env.WORKSTATION_SESSION_CAPTURED = nil
package.path = repository .. "/workstation/lua/?.lua;" .. repository .. "/workstation/?.lua;" .. package.path
local paths = require("workstation.paths")
for _, key in ipairs({
	"HOME",
	"USERPROFILE",
	"XDG_CONFIG_HOME",
	"XDG_DATA_HOME",
	"XDG_STATE_HOME",
	"XDG_CACHE_HOME",
	"XDG_RUNTIME_DIR",
	"WORKSTATION_CACHE",
	"TMPDIR",
}) do
	assert(vim.env[key]:sub(1, #paths.home) == paths.home, key .. " escaped target")
end
assert(paths.session.runtime_dir == session_runtime and paths.session.bus_address == "")
assert(vim.env.DBUS_SESSION_BUS_ADDRESS == nil)
local commands = require("workstation.commands")
local function executable(path, body)
	paths.write(path, "#!/bin/sh\nset -eu\n" .. body)
	assert(vim.uv.fs_chmod(path, 448))
end
-- First apply had no .node-version; refreshing runtime must not retain nil.
local versions = require("workstation.versions")
assert(versions.node == nil)
vim.fn.mkdir(scratch .. "/no-node-bin", "p")
assert(vim.uv.fs_symlink(vim.fn.exepath("sh"), scratch .. "/no-node-bin/sh"))
vim.env.PATH = scratch .. "/no-node-bin"
local adapter = require("workstation.platforms.unix").new({ name = "linux" })
adapter.configure_runtime()
versions.node = "99.1.0"
paths.write(paths.home .. "/.node-version", versions.node)
local bin = paths.local_dir .. "/opt/nvm/versions/node/v" .. versions.node .. "/bin"
executable(bin .. "/node", "printf 'pinned-node:%s\\n' \"$1\"\n")
paths.write(bin .. "/npm", "#!/usr/bin/env node\n")
vim.uv.fs_chmod(bin .. "/npm", 448)
adapter.configure_runtime()
assert(commands.capture(bin .. "/npm") == "pinned-node:" .. bin .. "/npm", "shebang did not resolve managed Node")
local current_path = vim.env.PATH
adapter.configure_runtime()
assert(vim.env.PATH == current_path, "refresh duplicated PATH")

-- Ownership/argv cases stub the service primitive and OS account identity;
-- real fake-child environment cases follow below. No live manager is reachable.
local retire = require("workstation.retire")
local execute, passwd = commands.execute, vim.uv.os_get_passwd
local calls = {}
commands.execute = function(command, args)
	table.insert(calls, command .. " " .. table.concat(args, " "))
end
vim.uv.os_get_passwd = function()
	return { homedir = scratch .. "/host", uid = vim.uv.getuid() }
end
local context = { paths = paths, platform = { name = "linux" } }
assert(retire.run(context) == false and #calls == 0)
vim.uv.os_get_passwd = function()
	return { homedir = paths.home, uid = vim.uv.getuid() }
end
assert(retire.run(context) == false and #calls == 0, "missing unit marked retired")
local unit = paths.home .. "/.config/systemd/user/workstation-subagents.service"
paths.write(unit, "unowned service")
assert(not pcall(retire.run, context) and #calls == 0)
paths.write(
	unit,
	"Description=Workstation GoAkt subagents daemon\nExecStart=%h/.local/bin/workstation-subagents --config %t/ws-subagents/config.toml\n"
)
vim.uv.fs_chmod(unit, 438)
assert(not pcall(retire.run, context) and #calls == 0, "writable unit accepted")
vim.uv.fs_chmod(unit, 384)
commands.execute = function()
	error("stubbed service failure")
end
assert(not pcall(retire.run, context))
local marker = vim.env.WORKSTATION_CACHE .. "/retire/subagents-service"
assert(not paths.exists(marker), "failed retirement recorded success")
commands.execute = function(command, args)
	table.insert(calls, command .. " " .. table.concat(args, " "))
end
assert(retire.run(context) and #calls == 2 and paths.exists(marker))
assert(retire.run(context) and #calls == 2, "successful retirement repeated")
vim.fn.delete(marker)
context.platform.name = "darwin"
paths.write(
	paths.home .. "/Library/LaunchAgents/com.workstation.subagents.plist",
	"<key>Label</key><string>com.workstation.subagents</string><string>"
		.. paths.home
		.. "/.local/bin/workstation-subagents</string>"
)
assert(retire.run(context) and calls[3]:find("launchctl bootout gui/", 1, true))
commands.execute, vim.uv.os_get_passwd = execute, passwd

-- Real service child ENV capture through direct Lua and the real shell launcher.
-- The only executable named systemctl is a scratch recorder; no manager is run.
local service_bin = scratch .. "/service-bin"
for _, name in ipairs({ "sh", "dirname", "readlink", "uname", "mkdir", "chmod" }) do
	vim.fn.mkdir(service_bin, "p")
	local path = host_commands[name]
	assert(vim.uv.fs_symlink(path, service_bin .. "/" .. name))
end
executable(
	service_bin .. "/systemctl",
	[[
printf '%s\n' "$XDG_RUNTIME_DIR" "${DBUS_SESSION_BUS_ADDRESS-unset}" "$HOME" "$XDG_CACHE_HOME" "$TMPDIR" "$*" >> "$TEST_SERVICE_LOG"
[ "${TEST_SERVICE_FAIL:-}" != yes ]
]]
)
local session_engine = scratch .. "/session-engine"
paths.write(session_engine .. "/bin/workstation", paths.read(repository .. "/workstation/bin/workstation"))
assert(vim.uv.fs_chmod(session_engine .. "/bin/workstation", 448))
paths.write(session_engine .. "/apps/cli/run.lua", paths.read(repository .. "/tests/fixtures/retire-session.lua"))
local child_home = scratch .. "/account"
local child_unit = child_home .. "/.config/systemd/user/workstation-subagents.service"
paths.write(child_unit, paths.read(unit))
assert(vim.uv.fs_chmod(child_unit, 384))
executable(child_home .. "/.local/opt/nvim/bin/nvim", "exec '" .. vim.v.progpath .. '\' "$@"\n')
local service_log = scratch .. "/service.log"
local child_marker = child_home .. "/.cache/workstation/retire/subagents-service"
assert(vim.uv.fs_symlink(session_runtime, scratch .. "/session-link"))
vim.fn.mkdir(scratch .. "/linked-bus-session", "p", 448)
assert(vim.uv.fs_chmod(scratch .. "/linked-bus-session", 448))
assert(vim.uv.fs_symlink(session_runtime .. "/bus", scratch .. "/linked-bus-session/bus"))
local base_env = {
	PATH = service_bin,
	HOME = scratch .. "/ambient-home",
	WORKSTATION_HOME = child_home,
	XDG_RUNTIME_DIR = session_runtime,
	TEST_REPOSITORY = repository,
	TEST_ACCOUNT_HOME = child_home,
	TEST_SERVICE_LOG = service_log,
	TEST_LAUNCHER = session_engine .. "/bin/workstation",
}
local function service_child(shell, extra, step)
	paths.write(service_log, "")
	vim.fn.delete(child_marker)
	local env = vim.tbl_extend("force", base_env, extra or {})
	local argv = shell and { env.TEST_LAUNCHER, step or "once" }
		or { vim.v.progpath, "-l", session_engine .. "/apps/cli/run.lua", step or "once" }
	local result = vim.system(argv, { env = env, clear_env = true, text = true }):wait()
	return result, paths.read(service_log)
end
for _, shell in ipairs({ false, true }) do
	for _, address in ipairs({ "", "unix:path=" .. session_runtime .. "/bus" }) do
		local result, captured =
			service_child(shell, address ~= "" and { DBUS_SESSION_BUS_ADDRESS = address } or {}, "repeat")
		assert(result.code == 0, result.stderr)
		local record = session_runtime
			.. "\n"
			.. (address == "" and "unset" or address)
			.. "\n"
			.. child_home
			.. "\n"
			.. child_home
			.. "/.cache\n"
			.. child_home
			.. "/.local/state/workstation/run/tmp\n"
		local pair = record
			.. "--user disable --now workstation-subagents.service\n"
			.. record
			.. "--user daemon-reload\n"
		assert(captured == pair .. pair, "service child environment/capture lost across repeat: " .. captured)
		assert(paths.exists(child_marker))
	end
	for _, extra in ipairs({
		{ XDG_RUNTIME_DIR = "" },
		{ XDG_RUNTIME_DIR = "relative" },
		{ XDG_RUNTIME_DIR = scratch .. "/missing-session" },
		{ XDG_RUNTIME_DIR = scratch .. "/session-link" },
		{ XDG_RUNTIME_DIR = scratch .. "/linked-bus-session" },
		{ XDG_RUNTIME_DIR = paths.home .. "/.local/state/workstation/run" },
		{ DBUS_SESSION_BUS_ADDRESS = "tcp:host=example.invalid,port=1" },
		{ DBUS_SESSION_BUS_ADDRESS = "unix:path=" .. session_runtime .. "/bus;unix:path=/other" },
	}) do
		local result, captured = service_child(shell, extra)
		assert(result.code ~= 0 and captured == "" and not paths.exists(child_marker), "invalid session reached child")
		assert(result.stderr:find("refusing retirement:", 1, true), result.stderr)
		assert(paths.read(child_unit) == paths.read(unit), "failure changed service file")
	end
	assert(vim.uv.fs_chmod(session_runtime, 493))
	local result, captured = service_child(shell)
	assert(result.code ~= 0 and captured == "" and not paths.exists(child_marker), "unsafe runtime accepted")
	assert(vim.uv.fs_chmod(session_runtime, 448))
	result, captured = service_child(shell, {
		TEST_ACCOUNT_HOME = scratch .. "/other-account",
		DBUS_SESSION_BUS_ADDRESS = "unix:path=" .. session_runtime .. "/bus",
	})
	assert(result.code == 0 and captured == "" and not paths.exists(child_marker), "alternate home reached child")
	result, captured = service_child(shell, { TEST_SERVICE_FAIL = "yes" })
	assert(result.code ~= 0 and captured ~= "" and not paths.exists(child_marker), "failed child recorded retirement")
end

-- Real checked argv children, but fake git and launcher in a tiny copied engine.
local fixture = scratch .. "/repo/workstation"
local run = fixture .. "/apps/cli/run.lua"
paths.write(run, paths.read(repository .. "/workstation/apps/cli/run.lua"))
local log = scratch .. "/update.log"
vim.env.TEST_LOG = log
vim.env.TEST_PULLED_LAUNCHER = fixture .. "/bin/workstation"
vim.env.TEST_PULLED_CONTENT = '#!/bin/sh\nset -eu\nprintf "%s\\n" "$1" >> "$TEST_LOG"\n[ "${TEST_FAIL:-}" != "$1" ]\n'
executable(
	scratch .. "/bin/git",
	'printf "git:%s\\n" "$*" >> "$TEST_LOG"\n[ "${TEST_FAIL:-}" != git ]\nprintf "%s" "$TEST_PULLED_CONTENT" > "$TEST_PULLED_LAUNCHER"\n'
)
executable(fixture .. "/bin/workstation", "exit 98\n")
vim.env.PATH = scratch .. "/bin:" .. vim.env.PATH
local original_app, original_provisioner = package.loaded["workstation.app"], package.loaded["workstation.provisioner"]
package.loaded["workstation.app"] = {
	create = function()
		return { context = context }
	end,
}
package.loaded["workstation.provisioner"] = {
	repo_root = function()
		return scratch .. "/repo"
	end,
}
local original_arg = arg
arg = { "update" }
for _, failure in ipairs({ "", "git", "bootstrap", "apply", "sync", "verify" }) do
	paths.write(log, "")
	executable(fixture .. "/bin/workstation", "exit 98\n")
	vim.env.TEST_FAIL = failure
	local ok = pcall(dofile, run)
	assert(ok == (failure == ""), "update status mismatch for " .. failure)
	local lines = vim.split(vim.trim(paths.read(log)), "\n")
	local expected = ({ git = 1, bootstrap = 2, apply = 3, sync = 4, verify = 5 })[failure] or 5
	assert(#lines == expected, "update did not stop at first failure")
	assert(lines[1] == "git:-C " .. scratch .. "/repo pull --ff-only")
	for index = 2, #lines do
		assert(lines[index] == ({ "bootstrap", "apply", "sync", "verify" })[index - 1])
	end
end
-- Bootstrap backend failure cannot publish or claim readiness. Successful
-- backend handoff installs a real public link, retained on repeated bootstrap.
local public = paths.local_dir .. "/bin/workstation"
arg = { "bootstrap" }
package.loaded["workstation.provisioner"].ensure_backend = function()
	error("fixture backend failure")
end
assert(not pcall(dofile, run) and not vim.uv.fs_lstat(public))
package.loaded["workstation.provisioner"].ensure_backend = function() end
dofile(run)
assert(vim.uv.fs_readlink(public) == fixture .. "/bin/workstation")
require("workstation.launcher").verify(fixture)
local inode = vim.uv.fs_lstat(public).ino
dofile(run)
assert(vim.uv.fs_lstat(public).ino == inode)
paths.write(log, "")
vim.env.TEST_FAIL = ""
local launched = vim.system({ public, "status" }, { cwd = "/", text = true }):wait()
assert(launched.code == 0 and paths.read(log) == "status\n")
vim.fn.delete(public)
for _, kind in ipairs({ "file", "directory", "link" }) do
	if kind == "file" then
		paths.write(public, "user-owned")
	elseif kind == "directory" then
		vim.fn.mkdir(public, "p")
		paths.write(public .. "/keep", "user-owned")
	else
		assert(vim.uv.fs_symlink(scratch .. "/missing-user-target", public))
	end
	assert(not pcall(dofile, run), "conflicting " .. kind .. " accepted")
	assert(not pcall(require("workstation.launcher").verify, fixture), "conflicting launcher verified")
	if kind == "file" then
		assert(paths.read(public) == "user-owned")
	elseif kind == "directory" then
		assert(paths.read(public .. "/keep") == "user-owned")
	else
		assert(vim.uv.fs_readlink(public) == scratch .. "/missing-user-target")
	end
	vim.fn.delete(public, kind == "directory" and "rf" or "")
end
arg = original_arg
package.loaded["workstation.app"], package.loaded["workstation.provisioner"] = original_app, original_provisioner
-- Exercise the actual apply refresh seam, not only the adapter in isolation.
local original_retire = package.loaded["workstation.retire"]
versions.node = nil
vim.fn.delete(paths.home .. "/.node-version")
adapter.configure_runtime()
local setup_ran = false
package.loaded["workstation.retire"] = { run = function() end }
package.loaded["workstation.provisioner"] = {
	apply = function()
		paths.write(paths.home .. "/.node-version", "99.1.0")
	end,
}
package.loaded["workstation.app"] = {
	create = function()
		return {
			context = { paths = paths, versions = versions, platform = adapter },
			runner = {
				run = function(_, step)
					assert(step == "setup" and versions.node == "99.1.0")
					assert(commands.capture(bin .. "/npm") == "pinned-node:" .. bin .. "/npm")
					setup_ran = true
				end,
			},
		}
	end,
}
arg = { "apply" }
dofile(run)
assert(setup_ran)
arg = original_arg
package.loaded["workstation.app"], package.loaded["workstation.provisioner"], package.loaded["workstation.retire"] =
	original_app, original_provisioner, original_retire
-- Backend provisioning is engine-owned and uses canonical exact metadata; no
-- actual backend download/install in this test.
local provision = require("workstation.provision")
local create = provision.create
local requested
provision.create = function()
	return {
		archive = function(spec)
			requested = spec
		end,
	}
end
require("workstation.provisioner").ensure_backend()
provision.create = create
local asset = vim.uv.os_uname().sysname == "Darwin" and "darwin_arm64" or "linux_x86_64"
assert(requested.sha256 == versions["chezmoi_" .. asset .. "_sha256"])
assert(requested.url == versions["chezmoi_" .. asset .. "_url"]:gsub("{V}", versions.chezmoi))
assert(
	requested.dest == paths.local_dir .. "/opt/chezmoi/bin/chezmoi"
		and requested.inner_path == "chezmoi"
		and requested.format == "tar"
)
session_bus:close()
vim.fn.delete(scratch, "rf")
print(
	"CLI tests passed (confinement, Node refresh, retirement child ENV/direct/shell/repeat/fail-closed, checked update, offline backend)"
)
