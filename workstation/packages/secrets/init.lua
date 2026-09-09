local commands = require("workstation.commands")
local provision = require("workstation.provision.recipes")

return function()
	return {
		id = "secrets",
		requires = { "foundation" },
		contributes = {
			provision.shell({
				target = ".profile",
				fragment = {
					id = "managed-op-env",
					order = 30,
					marker = "# chezmoi: managed op env",
					body = "[ -r /etc/pi/op.env ] && { set -a; . /etc/pi/op.env; set +a; }",
				},
			}),
		},
		setup = function(context)
			local v = context.versions
			local asset = context.platform.name == "darwin" and "darwin_arm64" or "linux_x86_64"
			context.provision.archive({
				url = v["onepassword_cli_" .. asset .. "_url"]:gsub("{V}", v.onepassword_cli),
				sha256 = v["onepassword_cli_" .. asset .. "_sha256"],
				format = "zip",
				inner_path = "op",
				dest = context.platform.tool("op"),
				mode = "755",
			})
		end,
		verify = function(context)
			local actual = commands.capture(context.platform.tool("op"), { "--version" })
			assert(
				actual == context.versions.onepassword_cli,
				("Expected 1Password CLI %s, got %s"):format(context.versions.onepassword_cli, actual)
			)
		end,
	}
end
