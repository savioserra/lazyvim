local M = {}

-- Lifecycle set: setup, sync, and verify run per package. retire is the
-- engine-wide pre-apply phase (workstation.retire runs it at the start of
-- apply); packages may also contribute retire handlers for their own cleanup.
local lifecycles = { retire = true, setup = true, sync = true, verify = true }

---@param graph table
---@param handlers table<string, table>
---@param context table
function M.new(graph, handlers, context)
	for _, specification in ipairs(graph.ordered) do
		local package_handlers = handlers[specification.id]
		assert(type(package_handlers) == "table", "missing lifecycle handlers for package " .. specification.id)
		for lifecycle, handler in pairs(package_handlers) do
			assert(
				handler == nil or (lifecycles[lifecycle] and type(handler) == "function"),
				specification.id .. " has invalid lifecycle handler " .. tostring(lifecycle)
			)
		end
	end

	return {
		run = function(_, lifecycle)
			assert(lifecycles[lifecycle], "unknown lifecycle: " .. tostring(lifecycle))
			for _, specification in ipairs(graph.ordered) do
				local handler = (handlers[specification.id] or {})[lifecycle]
				if handler then
					print(("\n==> %s package: %s"):format(lifecycle, specification.id))
					handler(context)
				end
			end
		end,
	}
end

return M
