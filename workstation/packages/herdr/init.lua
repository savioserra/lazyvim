local commands = require("workstation.commands")
local provision = require("workstation.provision.recipes")

return function()
	return {
		id = "herdr",
		requires = { "foundation" },
		contributes = {
			provision.chezmoi({
				target = ".local/bin/herdr",
				kind = "symlink",
				to = "../opt/herdr/bin/herdr",
			}),
		},
		setup = function(context)
			local v = context.versions
			local asset = context.platform.name == "darwin" and "darwin_arm64" or "linux_x86_64"
			context.provision.file({
				url = v["herdr_" .. asset .. "_url"]:gsub("{V}", v.herdr),
				sha256 = v["herdr_" .. asset .. "_sha256"],
				dest = context.paths.join(context.paths.local_dir, "opt", "herdr", "bin", "herdr"),
			})
		end,
		verify = function(context)
			-- Static verification only. Setup re-verifies the installed tree
			-- against the pinned digest; lifecycle commands never start, stop,
			-- attach or inspect a Herdr server, pane or session.
			local actual = commands.capture(context.platform.tool("herdr"), { "--version" })
			assert(vim.startswith(actual, "herdr " .. context.versions.herdr), "Unexpected Herdr: " .. actual)
		end,
	}
end
