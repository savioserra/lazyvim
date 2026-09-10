local commands = require("workstation.commands")
local managed_node = require("packages.node.managed")
local provision = require("workstation.provision.recipes")

local module_path = debug.getinfo(1, "S").source:gsub("^@", "")
local package_root = vim.fs.dirname(vim.fs.normalize(module_path))
local verifier = vim.fs.joinpath(package_root, "verify.mjs")

local HOOK_TARGET = ".pi/agent/extensions/herdr-agent-state.ts"

return function()
	return {
		id = "herdr-pi",
		requires = { "pi", "herdr", "pi-subagents" },
		contributes = {
			-- The only managed artifact: the exact official hook bytes bundled
			-- with the pinned Herdr release (integration revision 8). The file
			-- recipe deploys through the engine backend; an unmanaged existing
			-- file fails closed at apply and takeover is always an explicit
			-- operator decision, matching upstream's single-file contract.
			provision.chezmoi({
				target = HOOK_TARGET,
				kind = "file",
				asset = "files/" .. HOOK_TARGET,
			}),
		},
		verify = function(context)
			local asset_file = assert(io.open(vim.fs.joinpath(package_root, "files", HOOK_TARGET), "rb"))
			local expected = asset_file:read("*a")
			asset_file:close()
			local deployed = context.paths.read(context.paths.join(context.paths.home, HOOK_TARGET))
			assert(deployed == expected, "deployed Herdr hook drifted from the pinned official bytes")
			assert(deployed:find("HERDR_INTEGRATION_VERSION=8", 1, true), "Herdr integration marker missing")
			-- Discovery through Pi's real loader against an isolated agent
			-- directory containing only the deployed hook: no ambient user
			-- extensions execute, no Herdr environment is inherited, and no
			-- socket, server, pane, credential or model call is made.
			local npm = managed_node.executable(context, "npm")
			local node = managed_node.executable(context, "node")
			local npm_root = commands.capture(npm, { "root", "--global" })
			local package_root = context.paths.join(npm_root, "@earendil-works", "pi-coding-agent")
			commands.execute(node, {
				verifier,
				package_root,
				context.paths.join(context.paths.home, HOOK_TARGET),
			}, { cwd = context.paths.home })
		end,
	}
end
