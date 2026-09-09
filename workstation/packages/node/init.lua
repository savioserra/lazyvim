local commands = require("workstation.commands")
local provision = require("workstation.provision.recipes")

local function backend(context)
	return require("packages.node.unix")
end

-- The node capability owns the sole Node version pin asset, the managed nvm
-- shell loader and its startup-file fragments. versions.lua stays target-only
-- and nil-tolerant; `workstation apply` refreshes the pin in place before setup.
local startup_files = { ".profile", ".bashrc", ".zshrc" }

return function()
	local contributes = {
		provision.chezmoi({
			target = ".node-version",
			kind = "file",
			asset = "files/.node-version",
		}),
		provision.chezmoi({
			target = ".config/shell/nvm.sh",
			kind = "file",
			asset = "files/nvm.sh",
		}),
	}
	for _, target in ipairs(startup_files) do
		table.insert(
			contributes,
			provision.shell({
				target = target,
				fragment = {
					id = "managed-nvm",
					order = 20,
					marker = "# chezmoi: load managed nvm",
					body = '[ -r "$HOME/.config/shell/nvm.sh" ] && . "$HOME/.config/shell/nvm.sh"',
				},
			})
		)
	end
	return {
		id = "node",
		requires = { "foundation" },
		contributes = contributes,
		setup = function(context)
			backend(context).provision(context)
			backend(context).configure(context)
			context.platform.configure_runtime()
		end,
		verify = function(context)
			backend(context).verify(context)
			local actual = commands.capture("node", { "--version" })
			assert(
				actual == "v" .. context.versions.node,
				("Expected managed Node v%s, got %s"):format(context.versions.node, actual)
			)
		end,
	}
end
