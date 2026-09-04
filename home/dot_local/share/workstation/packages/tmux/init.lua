local commands = require("workstation.commands")

local plugins = {
	{
		name = "tpm",
		url = "https://github.com/tmux-plugins/tpm.git",
		commit = "e261deb1b47614eed3400089ce7197dc68acc4eb",
	},
	{
		name = "tmux2k",
		url = "https://github.com/2KAbhishek/tmux2k.git",
		commit = "07b3228b56c1a7b6109f00009df80b53f7eae892",
	},
	{
		name = "tmux-yank",
		url = "https://github.com/tmux-plugins/tmux-yank.git",
		commit = "acfd36e4fcba99f8310a7dfb432111c242fe7392",
	},
	{
		name = "vim-tmux-navigator",
		url = "https://github.com/christoomey/vim-tmux-navigator.git",
		commit = "e41c431a0c7b7388ae7ba341f01a0d217eb3a432",
	},
	{
		name = "tmux-resurrect",
		url = "https://github.com/tmux-plugins/tmux-resurrect.git",
		commit = "cff343cf9e81983d3da0c8562b01616f12e8d548",
	},
}

local function plugin_directory(context, name)
	return context.paths.join(context.paths.home, ".tmux", "plugins", name)
end

return function()
	return {
		id = "tmux",
		requires = { "foundation" },
		supported_hosts = { linux = true, darwin = true },
		setup = function(context)
			local root = context.paths.join(context.paths.home, ".tmux", "plugins")
			vim.fn.mkdir(root, "p")
			vim.fs.rm(context.paths.join(root, "tmux-fingers"), { recursive = true, force = true })
			for _, plugin in ipairs(plugins) do
				local checkout = plugin_directory(context, plugin.name)
				if not context.paths.exists(context.paths.join(checkout, ".git")) then
					commands.execute("git", { "clone", "--quiet", plugin.url, checkout })
				end
				commands.execute("git", { "-C", checkout, "fetch", "--quiet", "origin", plugin.commit })
				commands.execute("git", { "-C", checkout, "checkout", "--quiet", plugin.commit })
			end
		end,
		verify = function(context)
			for _, plugin in ipairs(plugins) do
				local actual =
					commands.capture("git", { "-C", plugin_directory(context, plugin.name), "rev-parse", "HEAD" })
				assert(actual == plugin.commit, ("%s: expected %s, got %s"):format(plugin.name, plugin.commit, actual))
			end
			assert(
				vim.uv.fs_readlink(context.paths.join(context.paths.home, ".config", "tmux", "tmux.conf")) == "../../.tmux.conf",
				"XDG tmux config must point at the managed legacy config"
			)
			local socket = "workstation-verify-" .. vim.uv.os_getpid()
			commands.execute("tmux", {
				"-L",
				socket,
				"-f",
				context.paths.join(context.paths.home, ".tmux.conf"),
				"new-session",
				"-d",
				"-s",
				"verify",
			})
			local ok, failure = pcall(function()
				assert(
					commands.capture("tmux", { "-L", socket, "display-message", "-p", "#S" }) == "verify",
					"tmux session did not start"
				)
				assert(
					commands.capture("tmux", { "-L", socket, "show-options", "-gqv", "@tmux2k-theme" }) == "catppuccin",
					"tmux2k theme was not loaded"
				)
				assert(
					commands.capture("tmux", { "-L", socket, "show-options", "-gqv", "@tmux2k-left-sep" }) == "|",
					"tmux2k is not using vertical separators"
				)
			end)
			commands.try_execute("tmux", { "-L", socket, "kill-server" })
			if not ok then
				error(failure)
			end
		end,
	}
end
