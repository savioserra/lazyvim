local validate = require("setup.runtime.contract")

local M = {}

local function supported(specification, host)
	return specification.supported_hosts == nil or specification.supported_hosts[host] == true
end

---@param specifications CapabilitySpec[]
---@param host string
function M.resolve(specifications, host)
	assert(type(host) == "string" and host ~= "", "graph resolution requires a host name")
	local capabilities, enabled = {}, {}
	for _, specification in ipairs(specifications) do
		validate(specification)
		assert(not capabilities[specification.id], "duplicate capability: " .. specification.id)
		capabilities[specification.id] = specification
		if supported(specification, host) then
			enabled[specification.id] = true
		end
	end
	for _, specification in ipairs(specifications) do
		for _, dependency in ipairs(specification.requires or {}) do
			assert(capabilities[dependency], specification.id .. " requires unknown capability " .. dependency)
		end
	end

	local ordered, visiting, visited = {}, {}, {}
	local function visit(id)
		if not enabled[id] or visited[id] then
			return
		end
		assert(not visiting[id], "capability dependency cycle at " .. id)
		visiting[id] = true
		for _, dependency in ipairs(capabilities[id].requires or {}) do
			assert(enabled[dependency], id .. " requires unsupported capability " .. dependency)
			visit(dependency)
		end
		visiting[id], visited[id] = nil, true
		table.insert(ordered, capabilities[id])
	end
	for _, specification in ipairs(specifications) do
		visit(specification.id)
	end

	return { ordered = ordered, enabled = enabled }
end

return M
