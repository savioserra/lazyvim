-- Actual check.sh and real nonrecursive suites, not fake Neovim/empty bodies.
-- check.sh passes the formatter frozen alongside the runtime before isolation.
local repository = vim.fn.getcwd()
local nvim = assert(vim.uv.fs_realpath(vim.v.progpath))
local stylua = assert(arg[1], "run through .github/scripts/check.sh (frozen formatter argument required)")
assert(stylua:sub(1, 1) == "/" and vim.fn.executable(stylua) == 1)
stylua = assert(vim.uv.fs_realpath(stylua))
local scratch = vim.fn.tempname()
local function write(path, contents, executable)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	vim.fn.writefile(vim.split(contents, "\n", { plain = true }), path)
	if executable then
		assert(vim.uv.fs_chmod(path, 448))
	end
end
local function read(path)
	return table.concat(vim.fn.readfile(path), "\n")
end
local function checked(argv)
	local result = vim.system(argv, { text = true }):wait()
	assert(result.code == 0, result.stderr)
end
local clone, home, bin = scratch .. "/source", scratch .. "/populated", scratch .. "/bin"
vim.fn.mkdir(clone, "p")
for _, path in ipairs({ "workstation", "chezmoi", ".stylua.toml", ".luarc.json", ".github" }) do
	checked({ "cp", "-R", repository .. "/" .. path, clone .. "/" .. path })
end
-- An explicit subset avoids recursion while retaining the real fresh-HOME
-- assertion and subsequent fake Node/npm writes that exposed the defect.
for _, path in ipairs({ "capabilities.test.lua", "package-provision.test.lua", "provision.test.lua", "fixtures" }) do
	vim.fn.mkdir(clone .. "/tests", "p")
	checked({ "cp", "-R", repository .. "/tests/" .. path, clone .. "/tests/" .. path })
end
write(home .. "/.node-version", read(repository .. "/workstation/packages/node/files/.node-version"))
for _, path in ipairs({ ".config/keep", ".pi/agent/auth.json", ".npmrc", ".profile", ".local/opt/nvm/alias/default" }) do
	write(home .. "/" .. path, "synthetic protected state; never source or execute")
	assert(vim.uv.fs_chmod(home .. "/" .. path, 256)) -- 0400
end
local node = vim.trim(read(home .. "/.node-version"))
for _, name in ipairs({ "node", "npm" }) do
	write(home .. "/.local/opt/nvm/versions/node/v" .. node .. "/bin/" .. name, "protected installed fixture", true)
end
-- The cloned check.sh probes for a trusted backend; a stub satisfies the
-- lookup because the cloned suites are inert copies in this regression.
write(home .. "/.local/opt/chezmoi/bin/chezmoi", "#!/bin/sh\nexit 0\n", true)
for path, target in pairs({
	[".local/opt/nvim/bin/nvim"] = nvim,
	[".local/share/nvim/mason/bin/stylua"] = stylua,
	["config-link"] = home .. "/.config/keep",
}) do
	vim.fn.mkdir(vim.fs.dirname(home .. "/" .. path), "p")
	assert(vim.uv.fs_symlink(target, home .. "/" .. path))
end
local function snapshot(root)
	local entries = {}
	local function scan(path)
		local stat = assert(vim.uv.fs_lstat(path))
		entries[path:sub(#root + 1)] = {
			type = stat.type,
			mode = stat.mode,
			ino = stat.ino,
			value = stat.type == "file" and read(path) or stat.type == "link" and vim.uv.fs_readlink(path) or nil,
		}
		if stat.type == "directory" then
			for name in vim.fs.dir(path) do
				scan(path .. "/" .. name)
			end
		end
	end
	scan(root)
	return entries
end
local tool_state = { snapshot(nvim), snapshot(stylua) }
vim.fn.mkdir(bin, "p")
-- Keep all ordinary commands/guards from the already controlled caller PATH.
-- Git here may only perform the final diff check; its marker proves completion.
write(
	bin .. "/git",
	'#!/bin/sh\n[ "$*" = "diff --check" ] || exit 97\nprintf "checks complete\\n" >> '
		.. vim.fn.shellescape(scratch .. "/events")
		.. "\n",
	true
)
local env = { HOME = home, WORKSTATION_HOME = home, PATH = bin .. ":" .. vim.env.PATH }
for _, name in ipairs({
	"TMPDIR",
	"TMP",
	"TEMP",
	"XDG_CONFIG_HOME",
	"XDG_CONFIG_DIRS",
	"XDG_DATA_HOME",
	"XDG_DATA_DIRS",
	"XDG_STATE_HOME",
	"XDG_CACHE_HOME",
	"XDG_RUNTIME_DIR",
	"WORKSTATION_CACHE",
}) do
	env[name] = home .. "/poison/" .. name
end
for _, name in ipairs({
	"BASH_ENV",
	"ENV",
	"SSH_AUTH_SOCK",
	"DBUS_SESSION_BUS_ADDRESS",
	"ANTHROPIC_API_KEY",
	"OP_SERVICE_ACCOUNT_TOKEN",
	"PI_CODING_AGENT_DIR",
	"NPM_CONFIG_USERCONFIG",
	"GIT_CONFIG_COUNT",
	"WORKSTATION_SESSION_CAPTURED",
}) do
	env[name] = "fixture-poison-not-a-credential"
end
-- The same real sentinel body in two suites checks per-suite freshness, every
-- writable root and clearing ambient auth/config (before importing the engine).
local sentinel = [[
assert(vim.env.HOME == vim.env.WORKSTATION_HOME)
assert(bit.band(vim.uv.fs_stat(vim.fs.dirname(vim.env.HOME)).mode, 511) == 448)
assert(bit.band(vim.uv.fs_stat(vim.env.HOME).mode, 511) == 448)
assert(not vim.uv.fs_stat(vim.env.HOME .. "/.node-version"))
assert(not vim.uv.fs_stat(vim.env.HOME .. "/seen"))
vim.fn.writefile({ "seen" }, vim.env.HOME .. "/seen")
assert(bit.band(vim.uv.fs_stat(vim.env.HOME .. "/seen").mode, 511) == 420)
for _, key in ipairs({ "TMPDIR", "TMP", "TEMP", "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS", "XDG_DATA_HOME", "XDG_DATA_DIRS", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR", "WORKSTATION_CACHE" }) do
 assert(vim.env[key]:sub(1, #vim.fs.dirname(vim.env.HOME) + 1) == vim.fs.dirname(vim.env.HOME) .. "/", key)
end
for _, key in ipairs({ "BASH_ENV", "ENV", "SSH_AUTH_SOCK", "DBUS_SESSION_BUS_ADDRESS", "ANTHROPIC_API_KEY", "OP_SERVICE_ACCOUNT_TOKEN", "PI_CODING_AGENT_DIR", "NPM_CONFIG_USERCONFIG", "GIT_CONFIG_COUNT", "WORKSTATION_SESSION_CAPTURED" }) do
 assert(vim.env[key] == nil, key)
end
assert(vim.env.GIT_CONFIG_GLOBAL == "/dev/null" and vim.env.GIT_CONFIG_NOSYSTEM == "1")
]]
for _, name in ipairs({ "a-isolation", "z-isolation" }) do
	write(clone .. "/tests/" .. name .. ".test.lua", sentinel)
end
-- Format only the synthetic sentinel sources so the real formatter check stays
-- enabled; all copied source/check/suite bodies are otherwise unchanged.
checked({
	stylua,
	"--config-path",
	repository .. "/.stylua.toml",
	clone .. "/tests/a-isolation.test.lua",
	clone .. "/tests/z-isolation.test.lua",
})
local before = snapshot(home)
local run_count = 0
local function run(argv)
	local result = vim.system(argv, { env = env, clear_env = true, cwd = clone, text = true }):wait()
	run_count = run_count + 1
	local log = vim.env.HOME .. "/check-evidence/" .. run_count
	write(log .. ".stdout", result.stdout)
	write(log .. ".stderr", result.stderr)
	write(log .. ".exit", tostring(result.code))
	return result
end
local result = run({ "sh", clone .. "/.github/scripts/check.sh" })
assert(result.code == 0, result.stdout .. result.stderr)
assert((result.stdout .. result.stderr):find("package provisioning tests passed", 1, true))
assert((result.stdout .. result.stderr):find("Lua and JSON syntax checks passed", 1, true))
assert((result.stdout .. result.stderr):find("provision tests passed (tar/ZIP", 1, true))
assert(read(scratch .. "/events") == "checks complete")
assert(vim.deep_equal(snapshot(home), before), "checks changed populated parent state")
write(clone .. "/tests/0-failure.test.lua", "os.exit(39)\n")
result = run({ "sh", clone .. "/.github/scripts/check.sh" })
assert(result.code == 39, result.stdout .. result.stderr)
assert(not (result.stdout .. result.stderr):find("package provisioning tests passed", 1, true))
assert(not (result.stdout .. result.stderr):find("Lua and JSON syntax checks passed", 1, true))
assert(read(scratch .. "/events") == "checks complete", "checks ran after first failure")
assert(vim.deep_equal(snapshot(home), before))
vim.fn.delete(clone .. "/tests/0-failure.test.lua")
-- Invoke the actual harness too. Only the copied launcher and prerequisite PATH
-- are fixture replacements: bootstrap copies this synthetic installed state;
-- apply/sync are inert, and verify is reached only after the real checks.
local harness = read(repository .. "/.github/scripts/test-apply.sh")
harness = harness:gsub("PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", function()
	return "PATH=" .. vim.fn.shellescape(env.PATH)
end)
write(clone .. "/.github/scripts/test-apply.sh", harness)
write(clone .. "/workstation/bin/workstation", [[#!/bin/sh
set -eu
case "$1" in
 bootstrap)
 cp -R ]] .. vim.fn.shellescape(home .. "/.") .. [[ "$HOME/"
 mkdir -p "$HOME/.local/bin"
 ln -s "$PWD/workstation/bin/workstation" "$HOME/.local/bin/workstation"
 ;;
 apply|sync) ;;
 verify) printf 'public verify\n' >> ]] .. vim.fn.shellescape(scratch .. "/events") .. [[ ;;
 *) exit 97 ;;
esac
]], true)
result = run({ "sh", clone .. "/.github/scripts/test-apply.sh", scratch .. "/harness-home" })
assert(result.code == 0, result.stdout .. result.stderr)
assert(read(scratch .. "/events") == "checks complete\nchecks complete\npublic verify")
assert(vim.deep_equal(snapshot(home), before))
assert(vim.deep_equal({ snapshot(nvim), snapshot(stylua) }, tool_state), "installed tool changed")
vim.fn.delete(scratch, "rf")
print(
	"check tests passed (real suites/checks, populated parent unchanged, exact first failure, real harness reaches fake public verify)"
)
