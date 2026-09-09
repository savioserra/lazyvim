local chezmoi = require("workstation.provision.chezmoi")
local profile_module = require("packages.nvim.profile")

local M = {}

-- The nvim-owned profile compositor. It collects validated nvim-profile
-- intents contributed through the generic envelope, fixes their explicit
-- domain order (Go, TypeScript, standard), and emits ONE attributed chezmoi
-- recipe for the shared deployed profile. Contributors keep fragment
-- attribution; the compositor never fabricates per-fragment file ownership.

M.id = "nvim-profile"
M.target = ".config/nvim/lua/languages/profile.lua"

---Compose collected intents. `collected` is the graph-ordered list of
---{ owner = <capability id>, spec = <nvim-profile spec> } records.
---@return table recipe, table profile, string[] owners
function M.compose(collected)
	assert(#collected > 0, "Neovim profile composition requires at least one intent")
	local intents, owners = {}, {}
	for index, record in ipairs(collected) do
		profile_module.validate_spec(record.spec)
		intents[index] =
			{ order = record.spec.order, entry = record.spec.entry, owner = record.owner, sequence = index }
		table.insert(owners, record.owner)
	end
	-- table.sort is not stable: equal orders keep their graph collection order.
	table.sort(intents, function(left, right)
		if left.order ~= right.order then
			return left.order < right.order
		end
		return left.sequence < right.sequence
	end)
	local profile = {}
	for index, intent in ipairs(intents) do
		profile[index] = intent.entry
	end
	profile_module.validate(profile)
	local recipe = chezmoi.recipe({
		target = M.target,
		kind = "file",
		content = profile_module.serialize(profile),
	})
	return recipe, profile, owners
end

return M
