local repository = vim.fn.getcwd()
package.path = repository
	.. "/workstation/?.lua;"
	.. repository
	.. "/workstation/?/init.lua;"
	.. repository
	.. "/workstation/lua/?.lua;"
	.. package.path
local commands = require("workstation.commands")
local paths = require("workstation.paths")
local execute, capture = commands.execute, commands.capture
local function forbidden()
	error("unexpected host command or download")
end
commands.execute, commands.capture = forbidden, forbidden
local provision = require("workstation.provision")
local create = provision.create
provision.create = function()
	return { archive = forbidden, directory = forbidden, file = forbidden }
end

-- Frozen expectations resolved from the six pre-migration externals at
-- 146fee8c; this fixture is evidence, never a runtime source of pins.
local expected = vim.json.decode(paths.read(repository .. "/tests/fixtures/package-provision.expected.json"))
local versions = require("workstation.versions")
local canonical_node = vim.trim(paths.read(repository .. "/workstation/packages/node/files/.node-version"))
assert(versions.node == nil, "test requires a fresh isolated HOME")
local graph = require("workstation.core.graph")
local materialize = require("workstation.core.materialize")
local runner = require("workstation.core.runner")
local packages = materialize.from_catalog(require("workstation.catalog"), { context = { paths = paths } })
assert(#packages.contributions == 13)
assert(packages.handlers.nvim.setup == nil, "Neovim must remain bootstrap-owned")
local original_arg = arg
arg = { "status" }
dofile(repository .. "/workstation/apps/cli/run.lua")
arg = original_arg
-- Loading, composing and actual CLI status cannot call any provision operation,
-- child process, provider or account probe (all would fail above).

for _, host in ipairs({ "linux", "darwin", "wsl" }) do
	local platform = host == "wsl" and "linux" or host
	local has, uname = vim.fn.has, vim.uv.os_uname
	vim.fn.has = function(feature)
		return ((feature == "linux" and platform == "linux") or (feature == "mac" and platform == "darwin")) and 1 or 0
	end
	vim.uv.os_uname = function()
		return {
			sysname = platform == "linux" and "Linux" or "Darwin",
			release = host == "wsl" and "microsoft-standard-WSL2" or "fixture",
		}
	end
	package.loaded["workstation.platforms"] = nil
	local adapter = require("workstation.platforms")
	assert(adapter.name == platform, "WSL must use Linux assets; Darwin uses its arm64 assets")
	vim.fn.has, vim.uv.os_uname = has, uname
	local events, emitted = {}, {}
	local v = vim.deepcopy(versions)
	v.node = canonical_node
	local context = {
		versions = v,
		paths = {
			home = paths.home,
			local_dir = paths.local_dir,
			join = paths.join,
			write = function(path, contents)
				table.insert(events, { "write", path, contents })
			end,
		},
		platform = {
			name = adapter.name,
			tool = adapter.tool,
			configure_runtime = function()
				table.insert(events, { "runtime" })
			end,
		},
		provision = {},
	}
	for _, kind in ipairs({ "archive", "directory", "file" }) do
		context.provision[kind] = function(spec)
			table.insert(emitted, { kind = kind, spec = spec })
			table.insert(events, { kind, spec.dest })
		end
	end
	commands.execute = function(command, args)
		assert(platform == "linux" and command == "fc-cache")
		assert(vim.deep_equal(args, { "-f", paths.local_dir .. "/share/fonts" }))
		table.insert(events, { "font-cache" })
	end
	local ordered = graph.resolve(packages.specifications, platform)
	local handlers = {}
	for _, spec in ipairs(ordered.ordered) do
		local id = spec.id
		if vim.list_contains({ "foundation", "fonts", "node", "go", "secrets" }, id) then
			handlers[id] = packages.handlers[id]
		else
			handlers[id] = {
				setup = function()
					table.insert(events, { "dependent", id })
				end,
			}
		end
	end
	local lifecycle = runner.new(ordered, handlers, context)
	lifecycle:run("setup")
	local expected_specs = {}
	for _, declaration in ipairs(expected[platform]) do
		if declaration.owner == "bootstrap" then
			local asset = platform == "linux" and "linux_x86_64" or "darwin_arm64"
			assert(versions.neovim == declaration.version)
			assert(versions["neovim_" .. asset .. "_url"]:gsub("{V}", versions.neovim) == declaration.url)
			assert(versions["neovim_" .. asset .. "_sha256"] == declaration.sha256)
		else
			local spec = vim.deepcopy(declaration)
			spec.owner, spec.key, spec.version, spec.kind = nil, nil, nil, nil
			spec.dest = paths.home .. "/" .. spec.dest
			expected_specs[spec.dest] = { kind = declaration.kind, spec = spec }
		end
	end
	assert(#emitted == 11, "expected six foundation assets, fonts, nvm, Node, Go, op")
	for _, actual in ipairs(emitted) do
		assert(
			vim.deep_equal(actual, expected_specs[actual.spec.dest]),
			"original declaration drift: " .. vim.inspect(actual)
		)
		expected_specs[actual.spec.dest] = nil
	end
	assert(next(expected_specs) == nil)
	local node_root = paths.local_dir .. "/opt/nvm/versions/node/v" .. canonical_node
	local event_index = platform == "linux" and 9 or 8
	assert(events[7][2]:find("JetBrainsMonoNerdFont", 1, true))
	if platform == "linux" then
		assert(events[8][1] == "font-cache")
	end
	assert(vim.deep_equal(events[event_index], { "directory", paths.local_dir .. "/opt/nvm" }))
	assert(vim.deep_equal(events[event_index + 1], { "directory", node_root }))
	assert(
		vim.deep_equal(
			events[event_index + 2],
			{ "write", paths.local_dir .. "/opt/nvm/alias/default", canonical_node .. "\n" }
		)
	)
	assert(events[event_index + 3][1] == "runtime")
	assert(vim.deep_equal(events[event_index + 4], { "dependent", "pi" }))
	-- Repeat emits identical narrow ownership declarations. Integrity/idempotence
	-- and non-exact recursive mutable-state preservation are exercised by provision.test.lua.
	local first_events, first_emitted = events, emitted
	events, emitted = {}, {}
	lifecycle:run("setup")
	assert(vim.deep_equal(events, first_events) and vim.deep_equal(emitted, first_emitted))
	for _, invalid in ipairs({ false, "", "../escape", "v24.19.0", "24.19" }) do
		v.node = invalid or nil
		events, emitted = {}, {}
		local ok, failure = pcall(packages.handlers.node.setup, context)
		assert(not ok and tostring(failure):find("run workstation apply", 1, true))
		assert(#emitted == 0 and #events == 0, "invalid pin provisioned/configured Node")
	end
	v.node = canonical_node
	for _, failure_at in ipairs({ 1, 2 }) do
		local count = 0
		context.provision.directory = function()
			count = count + 1
			if count == failure_at then
				error("stub extraction failure")
			end
		end
		events = {}
		assert(not pcall(packages.handlers.node.setup, context) and #events == 0, "failed provisioning configured Node")
		assert(count == failure_at)
	end
	commands.capture = function(command, args)
		assert(command == adapter.tool("op") and vim.deep_equal(args, { "--version" }), "secret/account/network probe")
		return versions.onepassword_cli
	end
	packages.handlers.secrets.verify(context)
	commands.execute, commands.capture = forbidden, forbidden
end

-- The real first-apply CLI refresh must feed the sole source pin to the actual
-- Node handler. File backend, retirement and provision operations are stubs;
-- only a tiny scratch fake Node child runs to test npm's env shebang resolution.
local sh = vim.fn.exepath("sh")
local no_node_bin = paths.home .. "/no-node-bin"
vim.fn.mkdir(no_node_bin, "p")
assert(vim.uv.fs_symlink(sh, no_node_bin .. "/sh"))
vim.env.PATH = no_node_bin
assert(vim.fn.executable("node") == 0)
versions.node = nil
local adapter = require("workstation.platforms.unix").new({ name = "linux" })
adapter.configure_runtime()
local node_bin = paths.local_dir .. "/opt/nvm/versions/node/v" .. canonical_node .. "/bin"
local requested = {}
local context = { paths = paths, versions = versions, platform = adapter, provision = {} }
context.provision.directory = function(spec)
	table.insert(requested, spec)
	if #requested == 2 then
		assert(versions.node == canonical_node and spec.dest == vim.fs.dirname(node_bin))
		paths.write(node_bin .. "/node", "#!/bin/sh\nprintf 'fixture-node:%s\\n' \"$1\"\n")
		paths.write(node_bin .. "/npm", "#!/usr/bin/env node\n")
		assert(vim.uv.fs_chmod(node_bin .. "/node", 448))
		assert(vim.uv.fs_chmod(node_bin .. "/npm", 448))
	end
end
local app, backend, retire =
	package.loaded["workstation.app"], package.loaded["workstation.provisioner"], package.loaded["workstation.retire"]
package.loaded["workstation.provisioner"] = {
	apply = function()
		assert(versions.node == nil)
		paths.write(
			paths.home .. "/.node-version",
			paths.read(repository .. "/workstation/packages/node/files/.node-version")
		)
	end,
}
package.loaded["workstation.retire"] = { run = function() end }
local dependent_ran = false
package.loaded["workstation.app"] = {
	create = function()
		return {
			context = context,
			graph = { ordered = {} },
			packages_roots = {},
			runner = {
				run = function(_, step)
					assert(step == "setup" and versions.node == canonical_node)
					assert(
						vim.env.PATH:sub(1, #node_bin + 1) == node_bin .. ":",
						"first apply did not refresh managed PATH"
					)
					packages.handlers.node.setup(context)
					assert(capture(node_bin .. "/npm") == "fixture-node:" .. node_bin .. "/npm")
					dependent_ran = true
				end,
			},
		}
	end,
}
arg = { "apply" }
dofile(repository .. "/workstation/apps/cli/run.lua")
assert(dependent_ran and #requested == 2)
for i, key in ipairs({ "nvm_sh", "node" }) do
	local declaration
	for _, value in ipairs(expected.linux) do
		if value.key == key then
			declaration = value
		end
	end
	assert(requested[i].url == declaration.url and requested[i].sha256 == declaration.sha256)
	assert(requested[i].exact == false, "npm/nvm mutable trees must never be exact")
end
assert(paths.read(paths.local_dir .. "/opt/nvm/alias/default") == canonical_node .. "\n")
arg = original_arg
package.loaded["workstation.app"], package.loaded["workstation.provisioner"], package.loaded["workstation.retire"] =
	app, backend, retire
commands.execute, commands.capture, provision.create = execute, capture, create

assert(vim.uv.fs_stat(repository .. "/chezmoi") == nil, "centralized chezmoi tree still exists")
local removals = require("workstation.provision.policy").legacy_removals
assert(#removals == 17, "expected the seventeen baseline tombstones")
assert(vim.list_contains(removals, ".local/share/workstation/versions.json"))
assert(not vim.list_contains(removals, ".local/share/workstation"))
assert(not vim.list_contains(removals, ".local/share/workstation/workstation/versions.json"))
print(
	"package provisioning tests passed (original pin/layout parity, Linux/WSL and simulated Darwin, sequencing, first apply/no ambient Node, mutable ownership, status/no probes)"
)
