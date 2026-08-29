local commands = require("workstation.commands")
local config_parser = require("packages.subagents.config")
local managed_node = require("packages.node.managed")
local metadata = require("packages.subagents.metadata")
local paths = require("workstation.paths")

local module_path = debug.getinfo(1, "S").source:gsub("^@", "")
local verifier = vim.fs.joinpath(vim.fs.dirname(vim.fs.normalize(module_path)), "verify.mjs")

local function extension_root(context, name)
	return context.paths.join(context.paths.home, ".pi", "agent", "extensions", name)
end

local function bridge_root(context)
	return extension_root(context, "hosted-pi-bridge")
end

local function actor_client_root(context)
	return extension_root(context, "actor-client")
end

local function dependency_version(context, root)
	local manifest = context.paths.join(root, "node_modules", "@bufbuild", "protobuf", "package.json")
	if not context.paths.exists(manifest) then
		return nil
	end
	local ok, value = pcall(vim.json.decode, context.paths.read(manifest))
	return ok and value.version or nil
end

local function repository_root(context)
	local candidates = {
		vim.env.CHEZMOI_WORKING_TREE,
		vim.env.CHEZMOI_SOURCE_DIR,
		vim.env.CHEZMOI_SOURCE_PATH,
		vim.env.PWD,
		context.paths.join(context.paths.home, ".local", "share", "chezmoi"),
	}
	for _, candidate in ipairs(candidates) do
		if
			candidate
			and candidate ~= ""
			and context.paths.exists(context.paths.join(candidate, "services", "subagents", "go.mod"))
		then
			return candidate
		end
	end
	error("subagents source module is unavailable; run chezmoi apply from the repository source checkout")
end

local function owner_uid(context)
	local home_stat = assert(vim.uv.fs_lstat(context.paths.home), "home directory is missing")
	return assert(home_stat.uid, "home owner uid is unavailable")
end

local function install_node_dependencies(context, root)
	if dependency_version(context, root) ~= "2.11.0" then
		commands.execute(
			managed_node.executable(context, "npm"),
			{ "ci", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund" },
			{ cwd = root }
		)
	end
end

local function install_daemon_binaries(context)
	local service_root = context.paths.join(repository_root(context), "services", "subagents")
	local bin = context.paths.join(context.paths.home, ".local", "bin")
	vim.fn.mkdir(bin, "p")
	local daemon = context.paths.join(bin, "workstation-subagents")
	local clientctl = context.paths.join(bin, "workstation-subagents-clientctl")
	commands.execute(
		context.platform.tool("go"),
		{ "build", "-mod=readonly", "-o", daemon, "./cmd/subagents" },
		{ cwd = service_root }
	)
	commands.execute(
		context.platform.tool("go"),
		{ "build", "-mod=readonly", "-o", clientctl, "./tools/clientctl" },
		{ cwd = service_root }
	)
	vim.uv.fs_chmod(daemon, 448)
	vim.uv.fs_chmod(clientctl, 448)
end

local function activate_service(context)
	if context.platform.name == "darwin" then
		local uid = owner_uid(context)
		local domain = "gui/" .. tostring(uid)
		local plist =
			context.paths.join(context.paths.home, "Library", "LaunchAgents", "com.workstation.subagents.plist")
		commands.try_execute("launchctl", { "bootstrap", domain, plist })
		commands.try_execute("launchctl", { "enable", domain .. "/com.workstation.subagents" })
		commands.execute("launchctl", { "kickstart", "-k", domain .. "/com.workstation.subagents" })
	else
		commands.execute("systemctl", { "--user", "daemon-reload" })
		commands.execute("systemctl", { "--user", "enable", "workstation-subagents.service" })
		commands.execute("systemctl", { "--user", "restart", "workstation-subagents.service" })
	end
end

return function()
	return {
		id = "subagents",
		requires = { "go", "pi" },
		supported_hosts = { linux = true, darwin = true },
		setup = function(context)
			install_node_dependencies(context, bridge_root(context))
			install_node_dependencies(context, actor_client_root(context))
			install_daemon_binaries(context)
			activate_service(context)
		end,
		verify = function(context)
			local directory = paths.join(paths.home, ".config", "workstation", "subagents")
			local config = paths.join(directory, "config.toml")
			local directory_stat = assert(vim.uv.fs_lstat(directory), "subagents config directory is missing")
			local config_stat = assert(vim.uv.fs_lstat(config), "subagents config is missing")
			metadata.verify(directory_stat, config_stat, owner_uid(context))
			local contents = paths.read(config)
			config_parser.verify_managed_active(contents)
			local asset = vim.fn.has("mac") == 1
					and paths.join(paths.home, "Library", "LaunchAgents", "com.workstation.subagents.plist")
				or paths.join(paths.home, ".config", "systemd", "user", "workstation-subagents.service")
			assert(paths.exists(asset), "active subagents service-manager asset is missing")
			local service_asset = paths.read(asset)
			if vim.fn.has("mac") == 1 then
				assert(
					service_asset:find("<key>AbandonProcessGroup</key><true/>", 1, true),
					"LaunchAgent must preserve exactly owned hosted processes for adoption"
				)
			else
				assert(
					service_asset:find("KillMode=process", 1, true),
					"systemd unit must preserve exactly owned hosted processes for adoption"
				)
			end
			local daemon = paths.join(paths.home, ".local", "bin", "workstation-subagents")
			local clientctl = paths.join(paths.home, ".local", "bin", "workstation-subagents-clientctl")
			assert(paths.exists(daemon), "subagents daemon executable is missing")
			assert(paths.exists(clientctl), "subagents client executable is missing")
			assert(
				dependency_version(context, bridge_root(context)) == "2.11.0",
				"hosted Pi bridge protobuf runtime is not installed"
			)
			assert(
				dependency_version(context, actor_client_root(context)) == "2.11.0",
				"actor client protobuf runtime is not installed"
			)
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
				{ verifier, pi_root, bridge_root(context), actor_client_root(context) },
				{ cwd = context.paths.home }
			)
		end,
	}
end
