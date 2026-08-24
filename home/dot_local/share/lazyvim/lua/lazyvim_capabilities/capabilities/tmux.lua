local commands = require("lazyvim_capabilities.commands")
local define = require("lazyvim_capabilities.contract")

local plugins = {
	{ "tpm", "https://github.com/tmux-plugins/tpm.git", "e261deb1b47614eed3400089ce7197dc68acc4eb" },
	{ "tmux2k", "https://github.com/2KAbhishek/tmux2k.git", "07b3228b56c1a7b6109f00009df80b53f7eae892" },
	{ "tmux-yank", "https://github.com/tmux-plugins/tmux-yank.git", "acfd36e4fcba99f8310a7dfb432111c242fe7392" },
	{
		"vim-tmux-navigator",
		"https://github.com/christoomey/vim-tmux-navigator.git",
		"e41c431a0c7b7388ae7ba341f01a0d217eb3a432",
	},
	{
		"tmux-resurrect",
		"https://github.com/tmux-plugins/tmux-resurrect.git",
		"cff343cf9e81983d3da0c8562b01616f12e8d548",
	},
}

local function directory(context, name)
	return context.paths.join(context.paths.home, ".tmux", "plugins", name)
end

return define({
	id = "tmux",
	requires = { "foundation" },
	supports = function(context)
		return context.platform.name ~= "win32"
	end,
	setup = function(context)
		local root = context.paths.join(context.paths.home, ".tmux", "plugins")
		vim.fn.mkdir(root, "p")
		vim.fs.rm(context.paths.join(root, "tmux-fingers"), { recursive = true, force = true })
		for _, plugin in ipairs(plugins) do
			local checkout = directory(context, plugin[1])
			if not context.paths.exists(context.paths.join(checkout, ".git")) then
				commands.execute("git", { "clone", "--quiet", plugin[2], checkout })
			end
			commands.try_execute("git", { "-C", checkout, "fetch", "--quiet", "origin", plugin[3] })
			commands.execute("git", { "-C", checkout, "checkout", "--quiet", plugin[3] })
		end
	end,
	verify = function(context)
		for _, plugin in ipairs(plugins) do
			local actual = commands.capture("git", { "-C", directory(context, plugin[1]), "rev-parse", "HEAD" })
			assert(actual == plugin[3], ("%s: expected %s, got %s"):format(plugin[1], plugin[3], actual))
		end
		commands.execute(
			"tmux",
			{ "-L", "ci", "-f", context.paths.join(context.paths.home, ".tmux.conf"), "new-session", "-d", "-s", "ci" }
		)
		local ok, error_message = pcall(function()
			assert(
				commands.capture("tmux", { "-L", "ci", "display-message", "-p", "#S" }) == "ci",
				"tmux session did not start"
			)
			assert(
				commands.capture("tmux", { "-L", "ci", "show-options", "-gqv", "@tmux2k-theme" }) == "catppuccin",
				"tmux2k theme was not loaded"
			)
		end)
		commands.try_execute("tmux", { "-L", "ci", "kill-server" })
		if not ok then
			error(error_message)
		end
	end,
})
