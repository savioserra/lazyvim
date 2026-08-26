local commands = require("setup.commands")
local managed_node = require("setup.features.node.managed")

local skills = {
	{
		directory = "manage-lazyvim-workstation",
		name = "manage-lazyvim-workstation",
	},
}

local module_path = debug.getinfo(1, "S").source:gsub("^@", "")
local verifier = vim.fs.joinpath(vim.fs.dirname(vim.fs.normalize(module_path)), "pi-skills", "verify.mjs")

return {
	verify = function(context)
		local npm = managed_node.executable(context, "npm")
		local node = managed_node.executable(context, "node")
		local npm_root = commands.capture(npm, { "root", "--global" })
		local package_root = context.paths.join(npm_root, "@earendil-works", "pi-coding-agent")
		for _, skill in ipairs(skills) do
			local skill_file =
				context.paths.join(context.paths.home, ".pi", "agent", "skills", skill.directory, "SKILL.md")
			local contents = context.paths.read(skill_file)
			assert(contents:match("^%-%-%-\n"), skill.name .. " skill is missing frontmatter")
			local declared_name = contents:match("\nname:%s*([%w%-]+)%s*\n")
			assert(declared_name == skill.name, skill.name .. " skill has the wrong name")
			assert(contents:match("\ndescription:%s*[^\n]+\n"), skill.name .. " skill is missing a description")
			commands.capture(node, { verifier, package_root, skill.name }, { cwd = context.paths.home })
		end
	end,
}
