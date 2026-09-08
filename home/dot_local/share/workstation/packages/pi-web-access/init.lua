local commands = require("workstation.commands")
local managed_node = require("packages.node.managed")

local package_name = "pi-web-access"

local module_path = debug.getinfo(1, "S").source:gsub("^@", "")
local verifier = vim.fs.joinpath(vim.fs.dirname(vim.fs.normalize(module_path)), "verify.mjs")

local function specification(context)
	return "npm:" .. package_name .. "@" .. context.versions.pi_web_access
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

return function()
	return {
		id = "pi-web-access",
		requires = { "pi" },
		setup = function(context)
			local npm = managed_node.executable(context, "npm")
			local pi = managed_node.executable(context, "pi")
			local expected = specification(context)
			local settings = read_json(context, context.paths.join(agent_dir(context), "settings.json"))
			if package_version(context) ~= context.versions.pi_web_access or not has_package(settings, expected) then
				local npm_specification = package_name .. "@" .. context.versions.pi_web_access
				local integrity = commands.capture(npm, { "view", npm_specification, "dist.integrity" })
				assert(
					integrity == context.versions.pi_web_access_integrity,
					"Unexpected pi-web-access integrity: " .. integrity
				)
				commands.execute(pi, { "install", expected })
			end
		end,
		verify = function(context)
			local expected = specification(context)
			local settings = read_json(context, context.paths.join(agent_dir(context), "settings.json"))
			assert(
				package_version(context) == context.versions.pi_web_access,
				"Unexpected pi-web-access package version"
			)
			assert(has_package(settings, expected), "Pi settings do not contain the pinned pi-web-access package")

			local lock = read_json(context, context.paths.join(agent_dir(context), "npm", "package-lock.json"))
			local locked = lock.packages and lock.packages["node_modules/" .. package_name]
			assert(locked and locked.version == context.versions.pi_web_access, "Unexpected pi-web-access lock version")
			assert(
				locked.integrity == context.versions.pi_web_access_integrity,
				"Unexpected pi-web-access lock integrity"
			)

			local npm = managed_node.executable(context, "npm")
			local node = managed_node.executable(context, "node")
			local npm_root = commands.capture(npm, { "root", "--global" })
			local pi_root = context.paths.join(npm_root, "@earendil-works", "pi-coding-agent")
			commands.capture(node, { verifier, pi_root }, { cwd = context.paths.home })
		end,
	}
end
