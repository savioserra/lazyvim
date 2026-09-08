local graph = require("workstation.core.graph")
local materialize = require("workstation.core.materialize")
local runner = require("workstation.core.runner")

local M = {}

function M.materialize(environment)
	return materialize.from_catalog(require("workstation.catalog"), environment)
end

function M.create(context)
	context = context or require("workstation.context").create()
	local packages = M.materialize({ context = context })
	local resolved = graph.resolve(packages.specifications, context.platform.name)
	return {
		context = context,
		graph = resolved,
		packages = packages.contributions,
		runner = runner.new(resolved, packages.handlers, context),
	}
end

return M
