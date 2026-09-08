-- Host-service retirement precedes file removal, but is never a scratch-home
-- operation. Identity comes from the OS account database, not inherited HOME.
local commands = require("workstation.commands")
local paths = require("workstation.paths")
local M = {}

-- Support the local account user bus only, not remote/multiple/abstract DBus
-- addresses. Inspect metadata, never probe/connect or invent a /run/user path.
local function linux_session(account)
	local session = paths.session
	local runtime = session.runtime_dir
	assert(
		runtime:sub(1, 1) == "/" and vim.uv.fs_realpath(runtime) == runtime,
		"refusing retirement: invalid session runtime"
	)
	local stat = vim.uv.fs_lstat(runtime)
	assert(
		stat and stat.type == "directory" and stat.uid == account.uid and bit.band(stat.mode, 4095) == 448,
		"refusing retirement: unsafe session runtime"
	)
	local bus = runtime .. "/bus"
	stat = vim.uv.fs_lstat(bus)
	assert(stat and stat.type == "socket" and stat.uid == account.uid, "refusing retirement: missing owned session bus")
	assert(
		session.bus_address == "" or (not bus:find("[^%w/_.%-]") and session.bus_address == "unix:path=" .. bus),
		"refusing retirement: unsupported session bus address"
	)
	-- vim.system stringifies false env values; use a complete normalized child
	-- environment so an absent DBus address stays unset, rather than "false".
	local env = vim.fn.environ()
	env.XDG_RUNTIME_DIR = runtime
	env.DBUS_SESSION_BUS_ADDRESS = session.bus_address ~= "" and session.bus_address or nil
	return env
end

function M.run(context)
	local account = vim.uv.os_get_passwd()
	local home = vim.uv.fs_realpath(context.paths.home)
	if
		not account
		or not home
		or vim.fs.normalize(context.paths.home) ~= vim.fs.normalize(account.homedir)
		or home ~= vim.uv.fs_realpath(account.homedir)
	then
		print("retire: skipped alternate target (no host service operations)")
		return false
	end
	local platform = context.platform.name
	local unit = platform == "linux" and paths.join(home, ".config/systemd/user/workstation-subagents.service")
		or paths.join(home, "Library/LaunchAgents/com.workstation.subagents.plist")
	local stat = vim.uv.fs_lstat(unit)
	if not stat then
		print("retire: no owned service file; skipped")
		return false
	end
	assert(
		stat.type == "file" and stat.uid == account.uid and bit.band(stat.mode, 18) == 0,
		"refusing retirement: unsafe service ownership"
	)
	local body = paths.read(unit)
	if platform == "linux" then
		assert(
			body:find("Description=Workstation GoAkt subagents daemon", 1, true)
				and body:find(
					"ExecStart=%h/.local/bin/workstation-subagents --config %t/ws-subagents/config.toml",
					1,
					true
				),
			"refusing retirement: unrecognized service"
		)
	else
		assert(
			platform == "darwin"
				and body:find("<key>Label</key><string>com.workstation.subagents</string>", 1, true)
				and body:find("<string>" .. home .. "/.local/bin/workstation-subagents</string>", 1, true),
			"refusing retirement: unrecognized service"
		)
	end
	local marker = paths.join(vim.env.WORKSTATION_CACHE, "retire", "subagents-service")
	if paths.exists(marker) then
		return true
	end
	-- Missing commands and failed operations abort: neither is recorded as success.
	if platform == "linux" then
		local options = { env = linux_session(account), clear_env = true }
		commands.execute("systemctl", { "--user", "disable", "--now", "workstation-subagents.service" }, options)
		commands.execute("systemctl", { "--user", "daemon-reload" }, options)
	else
		commands.execute("launchctl", { "bootout", ("gui/%d/com.workstation.subagents"):format(account.uid) })
	end
	paths.write(marker, "retired owned subagents service\n")
	return true
end

return M
