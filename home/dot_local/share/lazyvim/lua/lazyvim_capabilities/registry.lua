local definitions = {
	require("lazyvim_capabilities.capabilities.foundation"),
	require("lazyvim_capabilities.capabilities.fonts"),
	require("lazyvim_capabilities.capabilities.node"),
	require("lazyvim_capabilities.capabilities.nvim"),
	require("lazyvim_capabilities.capabilities.tmux"),
	require("lazyvim_capabilities.capabilities.languages.go"),
	require("lazyvim_capabilities.capabilities.languages.typescript"),
	require("lazyvim_capabilities.capabilities.languages.standard"),
}

local M = {}

function M.create(context)
	local capabilities, enabled = {}, {}
	for _, capability in ipairs(definitions) do
		assert(not capabilities[capability.id], "duplicate capability: " .. capability.id)
		capabilities[capability.id] = capability
		if capability.supports(context) then
			enabled[capability.id] = true
		end
	end
	for _, capability in ipairs(definitions) do
		for _, dependency in ipairs(capability.requires) do
			assert(capabilities[dependency], capability.id .. " requires unknown capability " .. dependency)
		end
	end

	local ordered, visiting, visited = {}, {}, {}
	local function visit(id)
		if not enabled[id] or visited[id] then
			return
		end
		assert(not visiting[id], "capability dependency cycle at " .. id)
		visiting[id] = true
		for _, dependency in ipairs(capabilities[id].requires) do
			assert(enabled[dependency], id .. " requires unsupported capability " .. dependency)
			visit(dependency)
		end
		visiting[id], visited[id] = nil, true
		table.insert(ordered, capabilities[id])
	end
	for _, capability in ipairs(definitions) do
		visit(capability.id)
	end

	local registry = { ordered = ordered }
	function registry:enhancements_for(target)
		local result = {}
		for _, capability in ipairs(self.ordered) do
			vim.list_extend(result, capability.enhancements[target] or {})
		end
		return result
	end
	function registry:run(lifecycle)
		for _, capability in ipairs(self.ordered) do
			if capability[lifecycle] then
				print(("\n==> %s capability: %s"):format(lifecycle, capability.id))
				local hook_context =
					vim.tbl_extend("force", context, { enhancements = self:enhancements_for(capability.id) })
				capability[lifecycle](hook_context)
			end
		end
	end
	return registry
end

return M
