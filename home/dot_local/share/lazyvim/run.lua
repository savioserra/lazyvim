local script = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fs.dirname(vim.fs.normalize(script))
package.path = table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", package.path }, ";")

local lifecycle = assert(arg[1], "usage: nvim -l run.lua <setup|sync|verify>")
assert(vim.tbl_contains({ "setup", "sync", "verify" }, lifecycle), "unknown lifecycle: " .. lifecycle)

if lifecycle == "sync" then
	vim.env.LAZYVIM_HEADLESS_SYNC = "1"
end

local application = require("setup.app").create()
application.runner:run(lifecycle)
print(("\n%s complete (%s)."):format(lifecycle, application.context.platform.name))
