local script = debug.getinfo(1, "S").source:gsub("^@", "")
-- Resolve to an absolute path: packages derive verifier paths from their module
-- source, which must stay absolute regardless of the caller's cwd.
script = vim.uv.fs_realpath(script) or script
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(script))))
package.path = table.concat(
	{ root .. "/?.lua", root .. "/?/init.lua", root .. "/lua/?.lua", root .. "/lua/?/init.lua", package.path },
	";"
)

local lifecycle = assert(arg[1], "usage: nvim -l run.lua <setup|sync|verify>")
assert(vim.tbl_contains({ "setup", "sync", "verify" }, lifecycle), "unknown lifecycle: " .. lifecycle)

if lifecycle == "sync" then
	vim.env.LAZYVIM_HEADLESS_SYNC = "1"
end

local application = require("workstation.app").create()
application.runner:run(lifecycle)
print(("\n%s complete (%s)."):format(lifecycle, application.context.platform.name))
