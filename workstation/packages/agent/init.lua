local commands = require("workstation.commands")
local managed_node = require("packages.node.managed")
local provision = require("workstation.provision.recipes")

local agent_package = "@earendil-works/pi-coding-agent"
local assigned_agents = { "worker", "delegate" }
local assigned_skill = "lazyvim"

local module_path = debug.getinfo(1, "S").source:gsub("^@", "")
local package_root = vim.fs.dirname(vim.fs.normalize(module_path))
local catalog_path = vim.fs.joinpath(package_root, "pi-packages.json")
local verify_root = vim.fs.joinpath(package_root, "verify")

local function read_json(context, path)
	if not context.paths.exists(path) then
		return {}
	end
	return vim.json.decode(context.paths.read(path))
end

-- The pinned catalog is package-owned source data, not target state: it is
-- read from the checkout directly, never through the target filesystem.
local function read_catalog()
	return vim.json.decode(table.concat(vim.fn.readfile(catalog_path), "\n"))
end

local function agent_dir(context)
	return context.paths.join(context.paths.home, ".pi", "agent")
end

local function pi_root(context)
	local npm = managed_node.executable(context, "npm")
	local root = commands.capture(npm, { "root", "--global" })
	return context.paths.join(root, "@earendil-works", "pi-coding-agent")
end

local function installed_pi_version(context, npm)
	local ok, root = pcall(commands.capture, npm, { "root", "--global" })
	if not ok then
		return nil
	end
	local manifest = context.paths.join(root, "@earendil-works", "pi-coding-agent", "package.json")
	local read_ok, contents = pcall(context.paths.read, manifest)
	if not read_ok then
		return nil
	end
	return vim.json.decode(contents).version
end

local function package_version(context, name)
	local manifest = context.paths.join(agent_dir(context), "npm", "node_modules", name, "package.json")
	local ok, contents = pcall(read_json, context, manifest)
	return ok and contents.version or nil
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

-- billion-context-pi ships its own acp_delegate sub-agent surface. pi-subagents is
-- the single delegation path on this workstation, so ACP's delegate tools stay off
-- while its compression tools (compress/decompress/search_context/acp_status) remain.
local function ensure_delegate_disabled(context)
	local acp_path = context.paths.join(context.paths.home, ".pi", "acp.json")
	local config = read_json(context, acp_path)
	if config.delegate == false then
		return
	end
	config.delegate = false
	context.paths.write(acp_path, vim.json.encode(config) .. "\n")
end

local function verifiers()
	local names = {}
	for name in vim.fs.dir(verify_root) do
		if name:sub(-4) == ".mjs" then
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names
end

return function()
	return {
		id = "agent",
		requires = { "node", "theme" },
		-- Derived pi UI themes render from the theme capability's data
		-- envelope: pi only reads theme files, so they are safe managed state,
		-- while pi's own settings.json (where the user picks
		-- "workstation-light/workstation-dark") stays pi-owned.
		-- The pi-subagents role definitions carry memory frontmatter (intrinsic
		-- to pi-subagents — no Hermes/Pi parent-memory dependency) and shadow
		-- the bundled builtins wholesale; re-diff these copies against the
		-- package builtins after pi-subagents upgrades or prompts drift.
		contributes = {
			provision.chezmoi({
				target = ".pi/agent/agents/worker.md",
				kind = "file",
				asset = "files/.pi/agent/agents/worker.md",
			}),
			provision.chezmoi({
				target = ".pi/agent/agents/reviewer.md",
				kind = "file",
				asset = "files/.pi/agent/agents/reviewer.md",
			}),
			provision.chezmoi({
				target = ".pi/agent/themes/workstation-dark.json",
				kind = "file",
				template = true,
				asset = "files/.pi/agent/themes/workstation-dark.json",
			}),
			provision.chezmoi({
				target = ".pi/agent/themes/workstation-light.json",
				kind = "file",
				template = true,
				asset = "files/.pi/agent/themes/workstation-light.json",
			}),
		},
		setup = function(context)
			local npm = managed_node.executable(context, "npm")
			local pi = managed_node.executable(context, "pi")

			-- The pi coding agent itself, pinned in the canonical versions.json.
			local expected_agent = context.versions.pi_coding_agent
			if installed_pi_version(context, npm) ~= expected_agent then
				local specification = agent_package .. "@" .. expected_agent
				local integrity = commands.capture(npm, { "view", specification, "dist.integrity" })
				assert(
					integrity == context.versions.pi_coding_agent_integrity,
					"Unexpected pi package integrity: " .. integrity
				)
				commands.execute(npm, { "install", "--global", specification, "--no-audit", "--no-fund" })
			end

			-- Internal pi packages: exact versions and registry integrity live in the
			-- package-local pi-packages.json catalog. Every install is delegated to the
			-- pinned pi CLI; the engine only asserts the catalog before delegating.
			local catalog = read_catalog()
			local settings_path = context.paths.join(agent_dir(context), "settings.json")
			local settings = read_json(context, settings_path)
			for _, entry in ipairs(catalog.pi_packages or {}) do
				local expected = "npm:" .. entry.name .. "@" .. entry.version
				if package_version(context, entry.name) ~= entry.version or not has_package(settings, expected) then
					local integrity =
						commands.capture(npm, { "view", entry.name .. "@" .. entry.version, "dist.integrity" })
					assert(integrity == entry.integrity, "Unexpected " .. entry.name .. " integrity: " .. integrity)
					commands.execute(pi, { "install", expected })
					settings = read_json(context, settings_path)
				end
			end

			ensure_agent_skills(context)
			ensure_delegate_disabled(context)
		end,
		verify = function(context)
			local npm = managed_node.executable(context, "npm")
			local pi = managed_node.executable(context, "pi")
			local expected_agent = context.versions.pi_coding_agent
			assert(
				installed_pi_version(context, npm) == expected_agent,
				"Unexpected globally installed pi package version"
			)
			local actual = commands.capture(pi, { "--version" })
			assert(actual == expected_agent, ("Expected pi %s, got %s"):format(expected_agent, actual))

			local settings = read_json(context, context.paths.join(agent_dir(context), "settings.json"))
			local lock = read_json(context, context.paths.join(agent_dir(context), "npm", "package-lock.json"))
			local catalog = read_catalog()
			for _, entry in ipairs(catalog.pi_packages or {}) do
				local expected = "npm:" .. entry.name .. "@" .. entry.version
				assert(
					package_version(context, entry.name) == entry.version,
					"Unexpected " .. entry.name .. " package version"
				)
				assert(
					has_package(settings, expected),
					"Pi settings do not contain the pinned " .. entry.name .. " package"
				)
				local locked = lock.packages and lock.packages["node_modules/" .. entry.name]
				assert(locked and locked.version == entry.version, "Unexpected " .. entry.name .. " lock version")
				assert(locked.integrity == entry.integrity, "Unexpected " .. entry.name .. " lock integrity")
			end

			verify_agent_skills(settings)

			local acp = read_json(context, context.paths.join(context.paths.home, ".pi", "acp.json"))
			assert(acp.delegate == false, "billion-context-pi delegate must stay disabled in acp.json")

			local node = managed_node.executable(context, "node")
			local root = pi_root(context)
			for _, name in ipairs(verifiers()) do
				commands.capture(node, { vim.fs.joinpath(verify_root, name), root }, { cwd = context.paths.home })
			end
		end,
	}
end
