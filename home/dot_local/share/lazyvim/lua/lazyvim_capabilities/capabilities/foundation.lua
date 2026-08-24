local commands = require("lazyvim_capabilities.commands")
local define = require("lazyvim_capabilities.contract")

local function prefix(actual, expected, label)
	assert(vim.startswith(actual, expected), ("%s: expected %s, got %s"):format(label, expected, actual))
end

return define({
	id = "foundation",
	verify = function(context)
		local v = context.versions
		prefix(commands.capture("rg", { "--version" }), "ripgrep " .. v.ripgrep, "ripgrep")
		prefix(commands.capture("fd", { "--version" }), "fd " .. v.fd_major .. ".", "fd")
		prefix(commands.capture("fzf", { "--version" }), v.fzf, "fzf")
		assert(
			commands.capture("lazygit", { "--version" }):find("version=" .. v.lazygit, 1, true),
			"Unexpected lazygit version"
		)
		assert(
			commands.capture("tree-sitter", { "--version" }):find(v.tree_sitter, 1, true),
			"Unexpected tree-sitter version"
		)
		if not (context.platform.name == "win32" and jit.arch == "arm64") then
			commands.capture(context.platform.tool("rainfrog"), { "--version" })
		end
	end,
})
