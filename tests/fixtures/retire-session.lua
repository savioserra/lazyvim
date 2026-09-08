-- Child-only fixture. Identity and PATH are supplied entirely by cli.test.lua;
-- the scratch systemctl recorder is the only service executable available.
local repository = assert(vim.env.TEST_REPOSITORY)
package.path = repository .. "/workstation/lua/?.lua;" .. package.path
local commands = require("workstation.commands")
local paths = require("workstation.paths")
local retire = require("workstation.retire")
vim.uv.os_get_passwd = function()
	return { homedir = assert(vim.env.TEST_ACCOUNT_HOME), uid = vim.uv.getuid() }
end
assert(vim.env.DBUS_SESSION_BUS_ADDRESS == nil, "ambient live bus leaked")
for _, key in ipairs({ "HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR", "TMPDIR" }) do
	assert(vim.env[key]:sub(1, #paths.home) == paths.home, key .. " escaped target")
end
retire.run({ paths = paths, platform = { name = "linux" } })
if arg[1] == "repeat" then
	vim.fn.delete(vim.env.WORKSTATION_CACHE .. "/retire/subagents-service")
	commands.execute(assert(vim.env.TEST_LAUNCHER), { "once" })
end
