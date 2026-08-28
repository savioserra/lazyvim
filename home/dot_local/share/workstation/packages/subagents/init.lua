local commands = require("workstation.commands")
local config_parser = require("packages.subagents.config")
local managed_node = require("packages.node.managed")
local metadata = require("packages.subagents.metadata")
local paths = require("workstation.paths")

local module_path = debug.getinfo(1, "S").source:gsub("^@", "")
local verifier = vim.fs.joinpath(vim.fs.dirname(vim.fs.normalize(module_path)), "verify.mjs")

local function bridge_root(context)
	return context.paths.join(context.paths.home, ".pi", "agent", "extensions", "hosted-pi-bridge")
end

local function bridge_dependency_version(context)
	local manifest = context.paths.join(bridge_root(context), "node_modules", "@bufbuild", "protobuf", "package.json")
	if not context.paths.exists(manifest) then
		return nil
	end
	local ok, value = pcall(vim.json.decode, context.paths.read(manifest))
	return ok and value.version or nil
end

return function()
	return {
		id = "subagents",
		requires = { "go", "pi" },
		supported_hosts = { linux = true, darwin = true },
		setup = function(context)
			if bridge_dependency_version(context) ~= "2.11.0" then
				commands.execute(
					managed_node.executable(context, "npm"),
					{ "ci", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund" },
					{ cwd = bridge_root(context) }
				)
			end
		end,
		verify = function(context)
			local directory = paths.join(paths.home, ".config", "workstation", "subagents")
			local config = paths.join(directory, "config.toml")
			local directory_stat = assert(vim.uv.fs_lstat(directory), "subagents config directory is missing")
			local config_stat = assert(vim.uv.fs_lstat(config), "subagents config is missing")
			metadata.verify(directory_stat, config_stat, assert(vim.uv.os_getuid(), "current uid is unavailable"))
			local contents = paths.read(config)
			config_parser.verify_inactive(contents)
			local asset = vim.fn.has("mac") == 1
					and paths.join(paths.home, "Library", "LaunchAgents", "com.workstation.subagents.plist")
				or paths.join(paths.home, ".config", "systemd", "user", "workstation-subagents.service")
			assert(paths.exists(asset), "inactive subagents service-manager asset is missing")
			assert(bridge_dependency_version(context) == "2.11.0", "hosted Pi bridge protobuf runtime is not installed")
			local lock =
				vim.json.decode(context.paths.read(context.paths.join(bridge_root(context), "package-lock.json")))
			local protobuf = lock.packages and lock.packages["node_modules/@bufbuild/protobuf"]
			assert(protobuf and protobuf.version == "2.11.0", "unexpected hosted Pi bridge protobuf lock version")
			assert(
				protobuf.integrity
					== "sha512-sBXGT13cpmPR5BMgHE6UEEfEaShh5Ror6rfN3yEK5si7QVrtZg8LEPQb0VVhiLRUslD2yLnXtnRzG035J/mZXQ==",
				"unexpected hosted Pi bridge protobuf lock integrity"
			)
			local npm_root = commands.capture(managed_node.executable(context, "npm"), { "root", "--global" })
			local pi_root = context.paths.join(npm_root, "@earendil-works", "pi-coding-agent")
			commands.capture(
				managed_node.executable(context, "node"),
				{ verifier, pi_root, bridge_root(context) },
				{ cwd = context.paths.home }
			)
		end,
	}
end
