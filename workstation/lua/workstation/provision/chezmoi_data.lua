local M = {}

-- The chezmoi data provider: publishes the generation's source-root
-- `.chezmoidata.toml` envelope. The file is never a home target; chezmoi
-- merges it into template data, so capability-owned tokens (theme roles)
-- reach every rendered template without any package owning another's target.
-- Construction is pure data; the composition root interprets the envelope,
-- pins it into the manifest and stages it with the rest of the generation.

M.id = "chezmoi-data"

local function is_nonempty_string(value)
	return type(value) == "string" and value ~= ""
end

---Pure recipe constructor: `provision.chezmoi_data({ content = ... })`. The
---envelope carries exactly one TOML body and no target: the source-root name
---is fixed by the backend contract, never chosen per recipe.
function M.recipe(options)
	assert(type(options) == "table", "chezmoi data recipe requires an options table")
	for field in pairs(options) do
		assert(field == "content", "chezmoi data recipe has unknown option " .. tostring(field))
	end
	assert(is_nonempty_string(options.content), "chezmoi data recipe requires a non-empty TOML content string")
	return { provider = M.id, spec = { content = options.content } }
end

---Deep domain validation of a materialized spec at collection time. A mutated
---or hand-built envelope cannot smuggle in a target or extra fields.
---@return string content the validated TOML body
function M.validate_spec(spec)
	assert(type(spec) == "table", "chezmoi data spec must be a table")
	for field in pairs(spec) do
		assert(field == "content", "chezmoi data spec has unknown field " .. tostring(field))
	end
	assert(is_nonempty_string(spec.content), "chezmoi data spec requires a non-empty TOML content string")
	return spec.content
end

return M
