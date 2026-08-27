local commands = require("workstation.commands")
local managed_node = require("packages.node.managed")

local module_path = debug.getinfo(1, "S").source:gsub("^@", "")
local verifier = vim.fs.joinpath(vim.fs.dirname(vim.fs.normalize(module_path)), "verify.mjs")

local function read_json(context, path)
	return vim.json.decode(context.paths.read(path))
end

local function extension_root(context)
	return context.paths.join(context.paths.home, ".pi", "agent", "extensions", "tmux-subagents")
end

local function dependency_version(context, name)
	local manifest = context.paths.join(extension_root(context), "node_modules", name, "package.json")
	if not context.paths.exists(manifest) then
		return nil
	end
	local ok, value = pcall(read_json, context, manifest)
	return ok and value.version or nil
end

return function()
	return {
		id = "pi-tmux-subagents",
		requires = { "pi-subagents", "tmux" },
		supported_hosts = { linux = true, darwin = true },
		setup = function(context)
			local root = extension_root(context)
			if
				dependency_version(context, "xstate") ~= context.versions.xstate
				or dependency_version(context, "terminal-kit") ~= context.versions.terminal_kit
			then
				local npm = managed_node.executable(context, "npm")
				commands.execute(
					npm,
					{ "ci", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund" },
					{ cwd = root }
				)
			end
			local config_path = context.paths.join(root, "config.json")
			local activation_path = context.paths.join(root, "activation.json")
			context.paths.write(
				activation_path,
				vim.json.encode({ schemaVersion = 1, configSha256 = vim.fn.sha256(context.paths.read(config_path)) })
					.. "\n"
			)
			assert(vim.uv.fs_chmod(activation_path, 384), "failed to secure tmux-subagents activation attestation")
		end,
		verify = function(context)
			local agent_dir = context.paths.join(context.paths.home, ".pi", "agent")
			local root = extension_root(context)
			local config = read_json(context, context.paths.join(root, "config.json"))
			assert(config.schemaVersion == 1, "tmux-subagents config schema is incompatible")
			assert(config.extensionVersion == context.versions.pi_tmux_subagents, "unexpected tmux-subagents version")
			assert(config.enabled == false, "tmux-subagents must remain disabled until its post-reload gate")
			assert(
				config.compatiblePiSubagentsVersion == context.versions.pi_subagents,
				"tmux-subagents targets the wrong pi-subagents version"
			)
			assert(config.runtime.enabled == true, "tmux-subagents renderer dependencies must be enabled")
			assert(config.runtime.xstateVersion == context.versions.xstate, "unexpected XState version")
			assert(
				config.runtime.terminalKitVersion == context.versions.terminal_kit,
				"unexpected Terminal Kit version"
			)
			assert(config.runtime.actorProtocolVersion == 1, "unexpected actor protocol version")
			local activation = read_json(context, context.paths.join(root, "activation.json"))
			assert(activation.schemaVersion == 1, "tmux-subagents activation schema is incompatible")
			assert(
				activation.configSha256 == vim.fn.sha256(context.paths.read(context.paths.join(root, "config.json"))),
				"tmux-subagents activation does not attest the managed config"
			)

			local lock = read_json(context, context.paths.join(root, "package-lock.json"))
			local xstate = lock.packages and lock.packages["node_modules/xstate"]
			local terminal_kit = lock.packages and lock.packages["node_modules/terminal-kit"]
			assert(xstate and xstate.version == context.versions.xstate, "unexpected XState lock version")
			assert(xstate.integrity == context.versions.xstate_integrity, "unexpected XState lock integrity")
			assert(
				terminal_kit and terminal_kit.version == context.versions.terminal_kit,
				"unexpected Terminal Kit lock version"
			)
			assert(
				terminal_kit.integrity == context.versions.terminal_kit_integrity,
				"unexpected Terminal Kit lock integrity"
			)
			assert(dependency_version(context, "xstate") == context.versions.xstate, "XState is not installed")
			assert(
				dependency_version(context, "terminal-kit") == context.versions.terminal_kit,
				"Terminal Kit is not installed"
			)
			assert(
				context.paths.exists(context.paths.join(root, "renderer", "main.mjs")),
				"tmux-subagents Terminal Kit renderer is missing"
			)
			assert(
				context.paths.exists(
					context.paths.join(context.paths.home, ".local", "bin", "workstation-tmux-subagents")
				),
				"tmux-subagents launcher is missing"
			)

			local npm = managed_node.executable(context, "npm")
			local node = managed_node.executable(context, "node")
			local npm_root = commands.capture(npm, { "root", "--global" })
			local pi_root = context.paths.join(npm_root, "@earendil-works", "pi-coding-agent")
			commands.capture(node, { verifier, pi_root, context.versions.pi_subagents }, { cwd = agent_dir })
		end,
	}
end
