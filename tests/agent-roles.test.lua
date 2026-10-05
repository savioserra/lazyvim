-- Agent role definition contract tests: the engine-owned pi-subagents
-- definitions land as plain managed files under .pi/agent/agents/, carry the
-- per-project memory frontmatter (intrinsic to pi-subagents — no Hermes/Pi
-- parent-memory dependency), and are byte-complete in the plan.
local repository = vim.fn.getcwd()
local scratch = vim.fn.tempname()
vim.env.WORKSTATION_HOME = scratch
package.path = table.concat({
	vim.fs.joinpath(repository, "workstation", "?.lua"),
	vim.fs.joinpath(repository, "workstation", "?", "init.lua"),
	vim.fs.joinpath(repository, "workstation", "lua", "?.lua"),
	vim.fs.joinpath(repository, "workstation", "lua", "?", "init.lua"),
	package.path,
}, ";")

local source = require("workstation.source")

local application = require("workstation.app").create()
local plan = source.plan(application)

local roles = {}
for _, entry in ipairs(plan.entries) do
	if entry.target == ".pi/agent/agents/worker.md" then
		roles.worker = entry
	elseif entry.target == ".pi/agent/agents/reviewer.md" then
		roles.reviewer = entry
	end
end

for _, name in ipairs({ "worker", "reviewer" }) do
	local entry = roles[name]
	assert(entry ~= nil, "the plan is missing the " .. name .. " role definition")
	assert(entry.type == "file", name .. " role definition must be a plain file")
	assert(not entry.template, name .. " role definition must not render as a template")
	assert(entry.bytes:sub(-1) == "\n", name .. " role definition must end with a newline")
	for _, marker in ipairs({ "memory:", "scope: project", "path: fleet" }) do
		assert(entry.bytes:find(marker, 1, true), name .. " role definition is missing " .. marker)
	end
end

vim.fn.delete(scratch, "rf")
print("agent role definition tests passed (plan wiring, memory frontmatter)")
