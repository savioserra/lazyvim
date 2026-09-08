local commands = require("workstation.commands")
local managed_node = require("packages.node.managed")

local extension_dir_name = "ntfy-notifier"

return function()
	return {
		id = "pi-ntfy-notifier",
		requires = { "pi" },
		verify = function(context)
			local extension_dir =
				context.paths.join(context.paths.home, ".pi", "agent", "extensions", extension_dir_name)

			local manifest_path = context.paths.join(extension_dir, "package.json")
			assert(context.paths.exists(manifest_path), "ntfy-notifier package manifest is missing")

			local manifest = vim.json.decode(context.paths.read(manifest_path))
			assert(
				manifest.version == context.versions.pi_ntfy_notifier,
				("Unexpected ntfy-notifier version: %s"):format(manifest.version)
			)
			assert(
				manifest.pi and manifest.pi.extensions and manifest.pi.extensions[1] == "./extensions/ntfy-notifier.ts",
				"ntfy-notifier manifest does not declare the extension entry"
			)

			for _, file in ipairs({ "extensions/ntfy-notifier.ts", "src/ntfy.js" }) do
				assert(
					context.paths.exists(context.paths.join(extension_dir, file)),
					"ntfy-notifier file missing: " .. file
				)
			end

			-- The extension is silent unless PI_NTFY_SERVER and PI_NTFY_TOPIC are set in the
			-- host environment; verification must stay independent of that configuration.
			local node = managed_node.executable(context, "node")
			commands.execute(node, { "--test", "test/ntfy.test.mjs" }, { cwd = extension_dir })
		end,
	}
end
