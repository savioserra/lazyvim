local commands = require("setup.commands")

local function assert_version_prefix(actual, expected, label)
	assert(vim.startswith(actual, expected), ("%s: expected %s, got %s"):format(label, expected, actual))
end

return {
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
		if not (context.platform.name == "win32" and jit.arch == "arm64") then
			assert(
				commands.capture(context.platform.tool("rainfrog"), { "--version" }):find(v.rainfrog, 1, true),
				"Unexpected rainfrog version"
			)
		end
	end,
}
