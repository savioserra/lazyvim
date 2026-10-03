-- Behavior suite for the agent capability: delegation of installs to the pi
-- CLI, catalog fail-closed integrity, setup idempotence, and verify contracts.
-- Runs in an isolated fixture HOME with stubbed commands and an in-memory
-- filesystem; the package is loaded from a scratch copy so catalog tampering
-- never touches repository source.

local repository = vim.fn.getcwd()
local root = vim.fs.joinpath(repository, "workstation")
package.path = table.concat({
	vim.fs.joinpath(root, "?.lua"),
	vim.fs.joinpath(root, "?", "init.lua"),
	vim.fs.joinpath(root, "lua", "?.lua"),
	vim.fs.joinpath(root, "lua", "?", "init.lua"),
	package.path,
}, ";")

local function read_json_file(path)
	return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

local function assert_fails(pattern, callback)
	local ok, failure = pcall(callback)
	assert(not ok, "expected operation to fail")
	assert(
		tostring(failure):find(pattern, 1, true),
		("expected failure containing %q, got %q"):format(pattern, tostring(failure))
	)
end

local versions = read_json_file(vim.fs.joinpath(root, "versions.json"))
local catalog = read_json_file(vim.fs.joinpath(root, "packages", "agent", "pi-packages.json"))
local first_entry = catalog.pi_packages[1]
local last_entry = catalog.pi_packages[#catalog.pi_packages]

-- Scratch copy of the package the suite loads and is allowed to tamper with.
local scratch = vim.fn.tempname()
vim.fn.mkdir(vim.fs.joinpath(scratch, "packages", "agent", "verify"), "p")
for _, name in ipairs(vim.fn.readdir(vim.fs.joinpath(root, "packages", "agent"))) do
	local source = vim.fs.joinpath(root, "packages", "agent", name)
	if vim.fn.filereadable(source) == 1 then
		vim.fn.writefile(vim.fn.readfile(source), vim.fs.joinpath(scratch, "packages", "agent", name))
	end
end
for _, name in ipairs(vim.fn.readdir(vim.fs.joinpath(root, "packages", "agent", "verify"))) do
	vim.fn.writefile(
		vim.fn.readfile(vim.fs.joinpath(root, "packages", "agent", "verify", name)),
		vim.fs.joinpath(scratch, "packages", "agent", "verify", name)
	)
end
package.path = table.concat({
	vim.fs.joinpath(scratch, "?.lua"),
	vim.fs.joinpath(scratch, "?", "init.lua"),
}, ";") .. ";" .. package.path

-- Managed tool stubs must exist before the capability module loads.
package.loaded["packages.node.managed"] = {
	executable = function(_, tool)
		return "/managed-bin/" .. tool
	end,
}

local commands = require("workstation.commands")
local captured, executed = {}, {}
local stub_pi_version = versions.pi_coding_agent
local files, writes = {}, {}
local agent_dir = "/fixture-home/.pi/agent"
local settings_path = agent_dir .. "/settings.json"
local lock_path = agent_dir .. "/npm/package-lock.json"
local acp_path = "/fixture-home/.pi/acp.json"
local global_manifest_path = "/managed-npm-root/@earendil-works/pi-coding-agent/package.json"

local function registry_integrity(name, version)
	if name == "@earendil-works/pi-coding-agent" then
		assert(
			version == versions.pi_coding_agent,
			"registry stub queried for unexpected pi version: " .. tostring(version)
		)
		return versions.pi_coding_agent_integrity
	end
	for _, entry in ipairs(catalog.pi_packages) do
		if entry.name == name then
			assert(version == entry.version, "registry stub queried for unexpected version of " .. name)
			return entry.integrity
		end
	end
	error("registry stub queried for unknown package: " .. name)
end

commands.capture = function(command, args)
	table.insert(captured, { command, args })
	if args[1] == "root" then
		return "/managed-npm-root"
	end
	if args[1] == "view" then
		local name, version = tostring(args[2]):match("^(.+)@([^@]+)$")
		return registry_integrity(name, version)
	end
	if command == "/managed-bin/pi" and args[1] == "--version" then
		return stub_pi_version
	end
	if command == "/managed-bin/node" then
		return ""
	end
	error("unexpected capture: " .. command .. " " .. vim.inspect(args))
end

commands.execute = function(command, args)
	table.insert(executed, { command, args })
	-- Simulate the delegated tools' real side effects so post-install state is
	-- coherent: pi install rewrites settings, manifests and the lock; npm
	-- install --global replaces the pi agent manifest.
	if command == "/managed-bin/pi" and args[1] == "install" then
		local name, version = tostring(args[2]):match("^npm:(.+)@([^@]+)$")
		assert(name, "stub pi install could not parse spec: " .. tostring(args[2]))
		local settings = files[settings_path] and vim.json.decode(files[settings_path]) or { packages = {} }
		settings.packages = settings.packages or {}
		local specification = ("npm:%s@%s"):format(name, version)
		if not vim.list_contains(settings.packages, specification) then
			table.insert(settings.packages, specification)
		end
		files[settings_path] = vim.json.encode(settings)
		files[("%s/npm/node_modules/%s/package.json"):format(agent_dir, name)] = vim.json.encode({ version = version })
		local lock = files[lock_path] and vim.json.decode(files[lock_path]) or { packages = {} }
		lock.packages = lock.packages or {}
		local integrity
		for _, entry in ipairs(catalog.pi_packages) do
			if entry.name == name then
				integrity = entry.integrity
			end
		end
		lock.packages["node_modules/" .. name] = { version = version, integrity = integrity }
		files[lock_path] = vim.json.encode(lock)
	elseif command == "/managed-bin/npm" and args[1] == "install" then
		local version = tostring(args[3]):match("@([^@]+)$")
		files[global_manifest_path] = vim.json.encode({ version = version })
	end
	return true
end

local paths_stub = {
	home = "/fixture-home",
	join = function(...)
		return table.concat({ ... }, "/")
	end,
	exists = function(path)
		return files[path] ~= nil
	end,
	read = function(path)
		local value = files[path]
		assert(value, "unexpected read: " .. path)
		return value
	end,
	write = function(path, contents)
		writes[path] = (writes[path] or 0) + 1
		files[path] = contents
	end,
}

local function reset_state()
	files, writes = {}, {}
	captured, executed = {}, {}
	stub_pi_version = versions.pi_coding_agent
end

local function write_satisfied_state()
	local settings = { packages = {} }
	local lock = { packages = {} }
	for _, entry in ipairs(catalog.pi_packages) do
		table.insert(settings.packages, ("npm:%s@%s"):format(entry.name, entry.version))
		lock.packages["node_modules/" .. entry.name] = { version = entry.version, integrity = entry.integrity }
		files[("%s/npm/node_modules/%s/package.json"):format(agent_dir, entry.name)] =
			vim.json.encode({ version = entry.version })
	end
	settings.subagents = {
		agentOverrides = {
			worker = { skills = { "lazyvim" } },
			delegate = { skills = { "lazyvim" } },
		},
	}
	files[settings_path] = vim.json.encode(settings)
	files[lock_path] = vim.json.encode(lock)
	files[acp_path] = vim.json.encode({ delegate = false })
	files[global_manifest_path] = vim.json.encode({ version = versions.pi_coding_agent })
end

local function read_settings()
	return vim.json.decode(files[settings_path])
end

local function has_install(predicate)
	for _, call in ipairs(executed) do
		if predicate(call[1], call[2]) then
			return true
		end
	end
	return false
end

local function contribution()
	return require("packages.agent")()
end

-- Satisfied state: setup must be a no-op — no installs, no registry queries,
-- no state rewrites. This is the delegation contract: the engine repairs
-- drift only, it never re-converges healthy state through the CLI.
reset_state()
write_satisfied_state()
contribution().setup({ versions = versions, paths = paths_stub })
assert(#executed == 0, "setup executed commands on satisfied state: " .. vim.inspect(executed))
for _, call in ipairs(captured) do
	assert(call[2][1] ~= "view", "setup queried the registry for a satisfied package")
end
assert(next(writes) == nil, "setup rewrote satisfied state: " .. vim.inspect(writes))

-- One missing package: exactly one delegated pi install with the pinned spec,
-- the integrity asserted before delegating, and the settings entry repaired.
reset_state()
write_satisfied_state()
files[("%s/npm/node_modules/%s/package.json"):format(agent_dir, last_entry.name)] = nil
local settings = read_settings()
for index, specification in ipairs(settings.packages) do
	if specification == ("npm:%s@%s"):format(last_entry.name, last_entry.version) then
		table.remove(settings.packages, index)
		break
	end
end
files[settings_path] = vim.json.encode(settings)
contribution().setup({ versions = versions, paths = paths_stub })
assert(
	vim.deep_equal(
		executed,
		{ { "/managed-bin/pi", { "install", ("npm:%s@%s"):format(last_entry.name, last_entry.version) } } }
	),
	"setup did not delegate exactly the missing package install: " .. vim.inspect(executed)
)
assert(vim.list_contains(read_settings().packages, ("npm:%s@%s"):format(last_entry.name, last_entry.version)))

-- Drifted global pi coding agent: repaired through npm with the pinned spec,
-- while satisfied internal packages are left untouched.
reset_state()
write_satisfied_state()
files[global_manifest_path] = vim.json.encode({ version = "0.0.1" })
contribution().setup({ versions = versions, paths = paths_stub })
assert(
	vim.deep_equal(executed, {
		{
			"/managed-bin/npm",
			{
				"install",
				"--global",
				("@earendil-works/pi-coding-agent@%s"):format(versions.pi_coding_agent),
				"--no-audit",
				"--no-fund",
			},
		},
	}),
	"pi agent drift was not repaired through npm: " .. vim.inspect(executed)
)
assert(not has_install(function(command)
	return command == "/managed-bin/pi"
end), "setup reinstalled satisfied internal packages")

-- Tampered catalog integrity fails closed before any install is delegated.
reset_state()
write_satisfied_state()
files[("%s/npm/node_modules/%s/package.json"):format(agent_dir, first_entry.name)] = nil
local tampered = read_json_file(vim.fs.joinpath(scratch, "packages", "agent", "pi-packages.json"))
tampered.pi_packages[1].integrity = "sha512-bogus"
vim.fn.writefile(
	vim.split(vim.json.encode(tampered), "\n"),
	vim.fs.joinpath(scratch, "packages", "agent", "pi-packages.json")
)
assert_fails("Unexpected " .. first_entry.name .. " integrity", function()
	contribution().setup({ versions = versions, paths = paths_stub })
end)
assert(#executed == 0, "setup delegated installs despite a tampered catalog")
-- Restore the pristine catalog: later scenarios verify against it.
vim.fn.writefile(
	vim.split(vim.json.encode(catalog), "\n"),
	vim.fs.joinpath(scratch, "packages", "agent", "pi-packages.json")
)

-- verify contracts -----------------------------------------------------------

-- Satisfied state verifies, and every pinned package gets its discovery probe.
reset_state()
write_satisfied_state()
contribution().verify({ versions = versions, paths = paths_stub })
local probes = 0
for _, call in ipairs(captured) do
	if call[1] == "/managed-bin/node" then
		probes = probes + 1
	end
end
assert(probes == #catalog.pi_packages, ("expected %d discovery probes, got %d"):format(#catalog.pi_packages, probes))

-- An unpinned settings entry must fail verify.
reset_state()
write_satisfied_state()
settings = read_settings()
for index, specification in ipairs(settings.packages) do
	if specification == ("npm:%s@%s"):format(first_entry.name, first_entry.version) then
		settings.packages[index] = "npm:" .. first_entry.name
		break
	end
end
files[settings_path] = vim.json.encode(settings)
assert_fails("Pi settings do not contain the pinned " .. first_entry.name .. " package", function()
	contribution().verify({ versions = versions, paths = paths_stub })
end)

-- Lock version and integrity drift must fail verify.
reset_state()
write_satisfied_state()
local lock = vim.json.decode(files[lock_path])
lock.packages["node_modules/" .. first_entry.name].version = "9.9.9"
files[lock_path] = vim.json.encode(lock)
assert_fails("Unexpected " .. first_entry.name .. " lock version", function()
	contribution().verify({ versions = versions, paths = paths_stub })
end)

reset_state()
write_satisfied_state()
lock = vim.json.decode(files[lock_path])
lock.packages["node_modules/" .. last_entry.name].integrity = "sha512-tampered"
files[lock_path] = vim.json.encode(lock)
assert_fails("Unexpected " .. last_entry.name .. " lock integrity", function()
	contribution().verify({ versions = versions, paths = paths_stub })
end)

-- A missing subagent skill policy must fail verify.
reset_state()
write_satisfied_state()
settings = read_settings()
settings.subagents.agentOverrides.delegate = nil
files[settings_path] = vim.json.encode(settings)
assert_fails("delegate subagent is missing the lazyvim skill", function()
	contribution().verify({ versions = versions, paths = paths_stub })
end)

-- Re-enabled ACP delegation must fail verify: pi-subagents is the single
-- delegation surface on this workstation.
reset_state()
write_satisfied_state()
files[acp_path] = vim.json.encode({ delegate = true })
assert_fails("delegate must stay disabled", function()
	contribution().verify({ versions = versions, paths = paths_stub })
end)

-- Global pi agent version drift must fail verify.
reset_state()
write_satisfied_state()
files[global_manifest_path] = vim.json.encode({ version = "0.0.1" })
assert_fails("Unexpected globally installed pi package version", function()
	contribution().verify({ versions = versions, paths = paths_stub })
end)

vim.fn.delete(scratch, "rf")
print("agent capability behavior tests passed")
