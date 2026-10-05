local provision = require("workstation.provision.recipes")
local tokens = require("packages.theme.tokens")

-- The theme capability: owns the canonical workstation color tokens and
-- publishes them as the generation's .chezmoidata.toml envelope. It deploys
-- no home target of its own; consumers (tmux, agent) render their templates
-- against the merged data through their own recipes, and require this
-- package so the envelope is always present whenever they are selected.
return function()
	return {
		id = "theme",
		-- Foundation is the catalog discipline for every HOME-writing capability:
		-- it keeps theme ordered with the other dependents, after runtime setup.
		requires = { "foundation" },
		supported_hosts = { linux = true, darwin = true },
		contributes = {
			provision.chezmoi_data({ content = tokens.chezmoidata() }),
		},
	}
end
