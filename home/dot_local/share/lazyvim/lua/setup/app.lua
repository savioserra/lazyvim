local M = {}

function M.specifications_for(profile)
	local profile_module = require("setup.features.nvim.profile")
	local specifications = {}
	for _, original in ipairs(require("setup.capabilities.catalog")) do
		local specification = vim.deepcopy(original)
		if specification.id == "nvim" then
			local seen = {}
			specification.requires = specification.requires or {}
			for _, dependency in ipairs(specification.requires) do
				seen[dependency] = true
			end
			for _, dependency in ipairs(profile_module.required_capabilities(profile)) do
				if not seen[dependency] then
					table.insert(specification.requires, dependency)
					seen[dependency] = true
				end
			end
		end
		table.insert(specifications, specification)
	end
	return specifications
end

function M.create(context)
	context = context or require("setup.context").create()
	local profile = require("setup.features.nvim.profile").load(context)
	local graph = require("setup.runtime.graph").resolve(M.specifications_for(profile), context.platform.name)
	local handlers = require("setup.features.catalog")(profile)
	return {
		context = context,
		graph = graph,
		runner = require("setup.runtime.runner").new(graph, handlers, context),
		profile = profile,
	}
end

return M
