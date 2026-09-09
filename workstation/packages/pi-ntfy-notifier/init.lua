local commands = require("workstation.commands")
local managed_node = require("packages.node.managed")
local provision = require("workstation.provision.recipes")

local extension_dir_name = "ntfy-notifier"

local payload_files = {
	"README.md",
	"extensions/ntfy-notifier.ts",
	"package.json",
	"src/ntfy.js",
	"test/ntfy.test.mjs",
}

return function()
	local contributes = {
		provision.chezmoi({ target = ".pi/agent", kind = "directory", private = true }),
	}
	for _, name in ipairs(payload_files) do
		table.insert(
			contributes,
			provision.chezmoi({
				target = ".pi/agent/extensions/ntfy-notifier/" .. name,
				kind = "file",
				asset = "files/.pi/agent/extensions/ntfy-notifier/" .. name,
			})
		)
	end
	-- The notifier still executes in future shells: stopping source
	-- management of its environment fragment is not removal.
	table.insert(
		contributes,
		provision.shell({
			target = ".profile",
			fragment = {
				id = "managed-ntfy-notifier-env",
				order = 40,
				marker = "# chezmoi: managed ntfy notifier env",
				body = "[ -r /etc/ntfy/notifier.env ] && { set -a; . /etc/ntfy/notifier.env; set +a; }",
			},
		})
	)
	return {
		id = "pi-ntfy-notifier",
		requires = { "pi" },
		contributes = contributes,
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
