local commands = require("workstation.commands")
local provision = require("workstation.provision.recipes")

local function assert_version_prefix(actual, expected, label)
	assert(vim.startswith(actual, expected), ("%s: expected %s, got %s"):format(label, expected, actual))
end

local startup_files = { ".profile", ".bashrc", ".zshrc" }

return function()
	local contributes = {}
	for _, target in ipairs(startup_files) do
		table.insert(
			contributes,
			provision.shell({
				target = target,
				fragment = {
					id = "user-local-bin",
					order = 10,
					marker = "# chezmoi: managed user-local bin",
					body = 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) [ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH" ;; esac',
				},
			})
		)
	end
	return {
		id = "foundation",
		contributes = contributes,
		setup = function(context)
			local v = context.versions
			local asset = context.platform.name == "darwin" and "darwin_arm64" or "linux_x86_64"
			local triple = context.platform.name == "darwin" and "aarch64-apple-darwin" or "x86_64-unknown-linux"
			for _, tool in ipairs({
				{
					"rg",
					"ripgrep",
					"ripgrep-"
						.. v.ripgrep
						.. "-"
						.. triple
						.. (context.platform.name == "linux" and "-musl" or "")
						.. "/rg",
				},
				{
					"fd",
					"fd",
					"fd-v" .. v.fd .. "-" .. triple .. (context.platform.name == "linux" and "-gnu" or "") .. "/fd",
				},
				{ "fzf", "fzf", "fzf" },
				{ "lazygit", "lazygit", "lazygit" },
				{ "tree-sitter", "tree_sitter", "tree-sitter" },
				{ "rainfrog", "rainfrog", "rainfrog" },
			}) do
				local pin = tool[2] .. "_" .. asset
				context.provision.archive({
					url = v[pin .. "_url"]:gsub("{V}", v[tool[2]]),
					sha256 = v[pin .. "_sha256"],
					format = tool[2] == "tree_sitter" and "zip" or "tar",
					inner_path = tool[3],
					dest = context.paths.join(context.paths.local_dir, "bin", tool[1]),
					mode = "755",
				})
			end
		end,
		verify = function(context)
			local v = context.versions
			assert_version_prefix(commands.capture("rg", { "--version" }), "ripgrep " .. v.ripgrep, "ripgrep")
			assert_version_prefix(commands.capture("fd", { "--version" }), "fd " .. v.fd, "fd")
			assert_version_prefix(commands.capture("fzf", { "--version" }), v.fzf, "fzf")
			assert(
				commands.capture("lazygit", { "--version" }):find("version=" .. v.lazygit, 1, true),
				"Unexpected lazygit version"
			)
			assert(
				commands.capture("tree-sitter", { "--version" }):find(v.tree_sitter, 1, true),
				"Unexpected tree-sitter version"
			)
			assert(
				commands.capture(context.platform.tool("rainfrog"), { "--version" }):find(v.rainfrog, 1, true),
				"Unexpected rainfrog version"
			)
		end,
	}
end
