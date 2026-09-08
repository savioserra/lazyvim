local commands = require("workstation.commands")
local managed_node = require("packages.node.managed")

local package_name = "pi-subagents"
local assigned_agents = { "worker", "delegate" }
local assigned_skill = "lazyvim"

local module_path = debug.getinfo(1, "S").source:gsub("^@", "")
local verifier = vim.fs.joinpath(vim.fs.dirname(vim.fs.normalize(module_path)), "verify.mjs")

local function specification(context)
	return "npm:" .. package_name .. "@" .. context.versions.pi_subagents
end

local function agent_dir(context)
	return context.paths.join(context.paths.home, ".pi", "agent")
end

local function read_json(context, path)
	if not context.paths.exists(path) then
		return {}
	end
	return vim.json.decode(context.paths.read(path))
end

local function package_manifest(context)
	return context.paths.join(agent_dir(context), "npm", "node_modules", package_name, "package.json")
end

local function package_version(context)
	local ok, manifest = pcall(read_json, context, package_manifest(context))
	return ok and manifest.version or nil
end

local function has_package(settings, expected)
	for _, entry in ipairs(settings.packages or {}) do
		if entry == expected then
			return true
		end
	end
	return false
end

local function skill_list(value)
	if value == nil then
		return {}
	end
	if type(value) == "string" then
		local values = {}
		for skill in value:gmatch("[^,%s]+") do
			table.insert(values, skill)
		end
		return values
	end
	assert(type(value) == "table", "subagent skills override must be a string or list")
	return vim.deepcopy(value)
end

local function ensure_agent_skills(context)
	local settings_path = context.paths.join(agent_dir(context), "settings.json")
	local settings = read_json(context, settings_path)
	local original = vim.deepcopy(settings)
	settings.subagents = settings.subagents or {}
	settings.subagents.agentOverrides = settings.subagents.agentOverrides or {}
	for _, agent in ipairs(assigned_agents) do
		local override = settings.subagents.agentOverrides[agent] or {}
		local skills = skill_list(override.skills)
		if not vim.list_contains(skills, assigned_skill) then
			table.insert(skills, assigned_skill)
		end
		override.skills = skills
		settings.subagents.agentOverrides[agent] = override
	end
	if not vim.deep_equal(settings, original) then
		context.paths.write(settings_path, vim.json.encode(settings) .. "\n")
	end
end

local function verify_agent_skills(settings)
	local overrides = settings.subagents and settings.subagents.agentOverrides or {}
	for _, agent in ipairs(assigned_agents) do
		local skills = skill_list(overrides[agent] and overrides[agent].skills)
		assert(vim.list_contains(skills, assigned_skill), agent .. " subagent is missing the lazyvim skill")
	end
end

return function()
	return {
		id = "pi-subagents",
		requires = { "pi", "pi-skills" },
		setup = function(context)
			local npm = managed_node.executable(context, "npm")
			local pi = managed_node.executable(context, "pi")
			local expected = specification(context)
			local settings_path = context.paths.join(agent_dir(context), "settings.json")
			local settings = read_json(context, settings_path)
			if package_version(context) ~= context.versions.pi_subagents or not has_package(settings, expected) then
				local npm_specification = package_name .. "@" .. context.versions.pi_subagents
				local integrity = commands.capture(npm, { "view", npm_specification, "dist.integrity" })
				assert(
					integrity == context.versions.pi_subagents_integrity,
					"Unexpected pi-subagents integrity: " .. integrity
				)
				commands.execute(pi, { "install", expected })
			end
			ensure_agent_skills(context)
		end,
		verify = function(context)
			local expected = specification(context)
			local settings = read_json(context, context.paths.join(agent_dir(context), "settings.json"))
			assert(package_version(context) == context.versions.pi_subagents, "Unexpected pi-subagents package version")
			assert(has_package(settings, expected), "Pi settings do not contain the pinned pi-subagents package")
			verify_agent_skills(settings)

			local lock = read_json(context, context.paths.join(agent_dir(context), "npm", "package-lock.json"))
			local locked = lock.packages and lock.packages["node_modules/" .. package_name]
			assert(locked and locked.version == context.versions.pi_subagents, "Unexpected pi-subagents lock version")
			assert(
				locked.integrity == context.versions.pi_subagents_integrity,
				"Unexpected pi-subagents lock integrity"
			)

			local npm = managed_node.executable(context, "npm")
			local node = managed_node.executable(context, "node")
			local npm_root = commands.capture(npm, { "root", "--global" })
			local pi_root = context.paths.join(npm_root, "@earendil-works", "pi-coding-agent")
			commands.capture(node, { verifier, pi_root }, { cwd = context.paths.home })
		end,
	}
end
