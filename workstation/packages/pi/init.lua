local commands = require("workstation.commands")
local managed_node = require("packages.node.managed")

local package_name = "@earendil-works/pi-coding-agent"

local function installed_version(context, npm)
	local ok, root = pcall(commands.capture, npm, { "root", "--global" })
	if not ok then
		return nil
	end
	local manifest = context.paths.join(root, "@earendil-works", "pi-coding-agent", "package.json")
	local read_ok, contents = pcall(context.paths.read, manifest)
	if not read_ok then
		return nil
	end
	return vim.json.decode(contents).version
end

return function()
	return {
		id = "pi",
		requires = { "node" },
		setup = function(context)
			local npm = managed_node.executable(context, "npm")
			local expected = context.versions.pi_coding_agent
			if installed_version(context, npm) == expected then
				return
			end
			local specification = package_name .. "@" .. expected
			local integrity = commands.capture(npm, { "view", specification, "dist.integrity" })
			assert(
				integrity == context.versions.pi_coding_agent_integrity,
				"Unexpected pi package integrity: " .. integrity
			)
			commands.execute(npm, { "install", "--global", specification, "--no-audit", "--no-fund" })
		end,
		verify = function(context)
			local npm = managed_node.executable(context, "npm")
			local pi = managed_node.executable(context, "pi")
			local expected = context.versions.pi_coding_agent
			assert(installed_version(context, npm) == expected, "Unexpected globally installed pi package version")
			local actual = commands.capture(pi, { "--version" })
			assert(actual == expected, ("Expected pi %s, got %s"):format(expected, actual))
		end,
	}
end
