local commands = require("workstation.commands")
local managed_node = require("packages.node.managed")

local package_name = "billion-context-pi"

local module_path = debug.getinfo(1, "S").source:gsub("^@", "")
local verifier = vim.fs.joinpath(vim.fs.dirname(vim.fs.normalize(module_path)), "verify.mjs")

local function specification(context)
	return "npm:" .. package_name .. "@" .. context.versions.billion_context_pi
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

return function()
	return {
		id = "billion-context-pi",
		requires = { "pi", "pi-subagents" },
		setup = function(context)
			local npm = managed_node.executable(context, "npm")
			local pi = managed_node.executable(context, "pi")
			local expected = specification(context)
			local settings = read_json(context, context.paths.join(agent_dir(context), "settings.json"))
			if
				package_version(context) ~= context.versions.billion_context_pi
				or not has_package(settings, expected)
			then
				local npm_specification = package_name .. "@" .. context.versions.billion_context_pi
				local integrity = commands.capture(npm, { "view", npm_specification, "dist.integrity" })
				assert(
					integrity == context.versions.billion_context_pi_integrity,
					"Unexpected billion-context-pi integrity: " .. integrity
				)
				commands.execute(pi, { "install", expected })
			end
			ensure_delegate_disabled(context)
		end,
		verify = function(context)
			local expected = specification(context)
			local settings = read_json(context, context.paths.join(agent_dir(context), "settings.json"))
			assert(
				package_version(context) == context.versions.billion_context_pi,
				"Unexpected billion-context-pi package version"
			)
			assert(has_package(settings, expected), "Pi settings do not contain the pinned billion-context-pi package")

			local acp = read_json(context, context.paths.join(context.paths.home, ".pi", "acp.json"))
			assert(acp.delegate == false, "billion-context-pi delegate must stay disabled in acp.json")

			local lock = read_json(context, context.paths.join(agent_dir(context), "npm", "package-lock.json"))
			local locked = lock.packages and lock.packages["node_modules/" .. package_name]
			assert(
				locked and locked.version == context.versions.billion_context_pi,
				"Unexpected billion-context-pi lock version"
			)
			assert(
				locked.integrity == context.versions.billion_context_pi_integrity,
				"Unexpected billion-context-pi lock integrity"
			)

			local npm = managed_node.executable(context, "npm")
			local node = managed_node.executable(context, "node")
			local npm_root = commands.capture(npm, { "root", "--global" })
			local pi_root = context.paths.join(npm_root, "@earendil-works", "pi-coding-agent")
			commands.capture(node, { verifier, pi_root }, { cwd = context.paths.home })
		end,
	}
end
