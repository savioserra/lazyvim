-- Engine-owned retirements, replacing chezmoi run_once_before scripts. Each
-- entry runs at most once per host (marker under the engine cache) at the START
-- of `workstation apply`, before chezmoi materializes home state, so a
-- retirement always precedes deletion of the files it cleans up after.
--
-- Entries are plain data: { description, commands = { { executable, argv } } }.
-- A command whose executable is absent on the host is skipped, and command
-- failures are reported but never abort apply - the run_once scripts these
-- replace used `|| true` for exactly that reason.

local commands = require("workstation.commands")
local paths = require("workstation.paths")

-- LuaJIT exposes varargs unpack as the global `unpack`; Lua 5.2+ as table.unpack.
local varargs_unpack = table.unpack or unpack

local M = {}

local entries = {
	{
		description = "disable and unload the removed workstation-subagents user service",
		commands = {
			{
				executable = "systemctl",
				argv = { "systemctl", "--user", "disable", "--now", "workstation-subagents.service" },
			},
			{ executable = "systemctl", argv = { "systemctl", "--user", "daemon-reload" } },
			{
				executable = "launchctl",
				argv = {
					"launchctl",
					"bootout",
					("gui/%d/com.workstation.subagents"):format(vim.uv.getuid()),
				},
			},
		},
	},
}

local function retire_root(context)
	local base = vim.env.WORKSTATION_CACHE
		or paths.join(vim.env.XDG_CACHE_HOME or paths.join(context.paths.home, ".cache"), "workstation")
	return paths.join(base, "retire")
end

---djb2 digest, the same scheme the provision cache uses for identity keys.
local function short_hash(key)
	local hash = 5381
	for index = 1, #key do
		hash = (hash * 33 + key:byte(index)) % 0x100000000
	end
	return ("%08x"):format(hash)
end

local function marker_path(context, description)
	return paths.join(retire_root(context), short_hash(description))
end

---Run every pending retirement entry exactly once. Failures are reported but
---never abort the apply lifecycle.
---@param context table runtime context
function M.run(context)
	for _, entry in ipairs(entries) do
		local marker = marker_path(context, entry.description)
		if not paths.exists(marker) then
			print(("==> retire: %s"):format(entry.description))
			for _, command in ipairs(entry.commands) do
				if vim.fn.executable(command.executable) == 1 then
					local ok, failure =
						commands.try_execute(command.argv[1], { select(2, varargs_unpack(command.argv)) })
					if not ok then
						print(("    warning: %s"):format(tostring(failure):match("^[^\n]+") or failure))
					end
				end
			end
			vim.fn.mkdir(vim.fs.dirname(marker), "p")
			paths.write(marker, entry.description)
		end
	end
end

return M
