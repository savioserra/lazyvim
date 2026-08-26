local M = {}

---@param graph table
---@param handlers table<string, table>
---@param context table
function M.new(graph, handlers, context)
	for _, specification in ipairs(graph.ordered) do
		local capability_handlers = handlers[specification.id]
		assert(type(capability_handlers) == "table", "missing feature handlers for capability " .. specification.id)
		for lifecycle, handler in pairs(capability_handlers) do
			assert(
				vim.tbl_contains({ "setup", "sync", "verify" }, lifecycle) and type(handler) == "function",
				specification.id .. " has invalid lifecycle handler " .. tostring(lifecycle)
			)
		end
	end

	return {
		run = function(_, lifecycle)
			assert(
				vim.tbl_contains({ "setup", "sync", "verify" }, lifecycle),
				"unknown lifecycle: " .. tostring(lifecycle)
			)
			for _, specification in ipairs(graph.ordered) do
				local handler = (handlers[specification.id] or {})[lifecycle]
				if handler then
					print(("\n==> %s capability: %s"):format(lifecycle, specification.id))
					handler(context)
				end
			end
		end,
	}
end

return M
