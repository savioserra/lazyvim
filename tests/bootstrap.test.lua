local repository = vim.fn.getcwd()
local scratch = vim.fn.tempname()
vim.fn.mkdir(scratch, "p")
local function write(path, data, executable)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	local file = assert(io.open(path, "wb"))
	file:write(data)
	file:close()
	if executable then
		assert(vim.uv.fs_chmod(path, 448))
	end
end
local function read(path)
	local file = assert(io.open(path, "rb"))
	local value = file:read("*a")
	file:close()
	return value
end
local function checked(argv, opts)
	local result = vim.system(argv, opts or { text = true }):wait()
	assert(result.code == 0, vim.inspect(argv) .. ": " .. (result.stderr or ""))
	return result
end
local engine = scratch .. "/clone/workstation"
for _, file in ipairs({ "bin/workstation", "bootstrap/install-runtime.sh", "bootstrap/generate.lua", "versions.json" }) do
	write(engine .. "/" .. file, read(repository .. "/workstation/" .. file), file == "bin/workstation")
end
-- Tiny synthetic runtime: no system nvim or node exists in the bootstrap PATH.
write(
	scratch .. "/archive/nvim-test/bin/nvim",
	[[#!/bin/sh
if [ "$1" = --version ]; then printf 'NVIM v0.12.4\n'; exit 0; fi
[ "${TEST_BACKEND_FAIL:-}" != yes ] || exit 45
printf '%s\n' "$@" > "$HOME/handoff"
printf '%s\n' "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" "$WORKSTATION_CACHE" "$TMPDIR" > "$HOME/environment"
]],
	true
)
local archive = scratch .. "/runtime.tar.gz"
checked({ "tar", "-czf", archive, "-C", scratch .. "/archive", "nvim-test" })
-- Both simulated hosts use fixture-local command names backed by just one
-- available host hash implementation. Never require the other OS's tool.
local hash_tool = vim.fn.exepath("sha256sum")
local hash_args = ""
if hash_tool == "" then
	hash_tool = vim.fn.exepath("shasum")
	hash_args = " -a 256"
end
assert(hash_tool ~= "", "test prerequisite missing: sha256sum or shasum")
local hash_command = hash_args == "" and { hash_tool, archive } or { hash_tool, "-a", "256", archive }
local hash = checked(hash_command).stdout:match("^%x+")
local versions = vim.json.decode(read(engine .. "/versions.json"))
versions.neovim_linux_x86_64_sha256, versions.neovim_darwin_arm64_sha256 = hash, hash
write(engine .. "/versions.json", vim.json.encode(versions))
checked({ vim.v.progpath, "-l", engine .. "/bootstrap/generate.lua" })
checked({ vim.v.progpath, "-l", repository .. "/workstation/bootstrap/generate.lua", "--check" })
local bin = scratch .. "/bin"
vim.fn.mkdir(bin, "p")
for _, command in ipairs({
	"sh",
	"dirname",
	"readlink",
	"mkdir",
	"chmod",
	"cut",
	"rm",
	"sleep",
	"cp",
	"gzip",
}) do
	local path = vim.fn.exepath(command)
	assert(path ~= "", "test prerequisite missing: " .. command)
	assert(vim.uv.fs_symlink(path, bin .. "/" .. command))
end
local hash_exec = "exec " .. vim.fn.shellescape(hash_tool) .. hash_args .. ' "$@"\n'
write(bin .. "/sha256sum", "#!/bin/sh\n" .. hash_exec, true)
write(bin .. "/shasum", '#!/bin/sh\n[ "$1" = -a ] && [ "$2" = 256 ] || exit 2\nshift 2\n' .. hash_exec, true)
local cold_path = checked({ "sh", "-c", "! command -v node && ! command -v nvim" }, {
	env = { PATH = bin },
	clear_env = true,
	text = true,
})
assert(cold_path.stdout == "", "bootstrap fixture acquired ambient Node/Neovim")
write(
	bin .. "/uname",
	'#!/bin/sh\ncase "$1" in -s) echo "${TEST_OS:-Linux}" ;; -m) echo "${TEST_ARCH:-x86_64}" ;; esac\n',
	true
)
write(
	bin .. "/curl",
	[[#!/bin/sh
set -eu
printf 'download\n' >> "$TEST_DOWNLOAD_LOG"
[ "${TEST_CURL_FAIL:-}" != yes ] || exit 42
[ "${TEST_SLOW:-}" != yes ] || sleep 1
while [ "$1" != -o ]; do shift; done
cp "$TEST_ARCHIVE" "$2"
]],
	true
)
write(
	bin .. "/tar",
	'#!/bin/sh\n[ "${TEST_EXTRACT_FAIL:-}" != yes ] || [ "$1" != -xf ] || exit 43\nexec "'
		.. vim.fn.exepath("tar")
		.. '" "$@"\n',
	true
)
write(
	bin .. "/mv",
	'#!/bin/sh\ncase "$1" in */stage) [ "${TEST_ACTIVATE_FAIL:-}" != yes ] || exit 44 ;; esac\nexec "'
		.. vim.fn.exepath("mv")
		.. '" "$@"\n',
	true
)
local home = scratch .. "/target"
local log = scratch .. "/downloads"
local environment = vim.fn.environ()
environment.PATH, environment.HOME, environment.WORKSTATION_HOME = bin, scratch .. "/ambient", home
environment.TEST_ARCHIVE, environment.TEST_DOWNLOAD_LOG = archive, log
for _, key in ipairs({
	"XDG_CONFIG_HOME",
	"XDG_DATA_HOME",
	"XDG_STATE_HOME",
	"XDG_CACHE_HOME",
	"XDG_RUNTIME_DIR",
	"WORKSTATION_CACHE",
}) do
	environment[key] = scratch .. "/ambient/" .. key
end
local function launch(extra, target)
	local env = vim.tbl_extend("force", environment, extra or {})
	if target then
		env.WORKSTATION_HOME = target
	end
	return vim.system(
		{ engine .. "/bin/workstation", "bootstrap" },
		{ env = env, clear_env = true, cwd = "/", text = true }
	)
		:wait()
end
assert(launch().code == 0, "cold bootstrap failed")
assert(read(home .. "/handoff") == "-l\n" .. engine .. "/apps/cli/run.lua\nbootstrap\n", "missing Lua handoff")
for line in read(home .. "/environment"):gmatch("[^\n]+") do
	assert(line:sub(1, #home) == home, "ambient writable root leaked")
end
assert(not vim.uv.fs_stat(scratch .. "/ambient"))
assert(launch().code == 0 and read(log) == "download\n", "repeat bootstrap downloaded again")
write(home .. "/.local/opt/nvim/bin/nvim", "tampered runtime\n", true)
write(home .. "/.local/opt/nvim/stale", "stale runtime member")
assert(launch().code == 0 and read(log) == "download\n", "installed runtime drift did not repair from verified cache")
assert(not vim.uv.fs_stat(home .. "/.local/opt/nvim/stale"))
-- Tampered bootstrap cache must be reacquired, never extracted.
write(home .. "/.cache/workstation/bootstrap/" .. hash, "corrupt")
assert(launch().code == 0 and read(log) == "download\ndownload\n")
-- Failures never discard an existing good runtime; lock/stage are cleaned.
write(home .. "/.local/opt/nvim/previous-good", "keep")
for _, extra in ipairs({ { TEST_EXTRACT_FAIL = "yes" }, { TEST_ACTIVATE_FAIL = "yes" } }) do
	assert(launch(extra).code ~= 0)
	assert(read(home .. "/.local/opt/nvim/previous-good") == "keep")
	assert(not vim.uv.fs_stat(home .. "/.local/opt/.nvim-bootstrap.lock"))
end
write(home .. "/.cache/workstation/bootstrap/" .. hash, "bad")
assert(launch({ TEST_CURL_FAIL = "yes" }).code ~= 0)
assert(read(home .. "/.local/opt/nvim/previous-good") == "keep")
local wrong = scratch .. "/wrong-archive"
write(wrong, "untrusted")
assert(launch({ TEST_ARCHIVE = wrong }).code ~= 0)
assert(read(home .. "/.local/opt/nvim/previous-good") == "keep")
local failed_home = scratch .. "/failed-backend"
local failed_backend = launch({ TEST_BACKEND_FAIL = "yes" }, failed_home)
assert(failed_backend.code == 45 and not failed_backend.stdout:find("bootstrap complete", 1, true))
assert(not vim.uv.fs_lstat(failed_home .. "/.local/bin/workstation"))
-- The synthetic shell runtime above proves cold bootstrap without any ambient
-- Node/Neovim. Separately use the test host to exercise real link publication,
-- then execute that installed real launcher from an unrelated cwd.
assert(launch().code == 0)
vim.env.WORKSTATION_HOME = home
package.path = repository .. "/workstation/lua/?.lua;" .. package.path
require("workstation.launcher").install(engine)
local installed_result = vim.system(
	{ home .. "/.local/bin/workstation", "status" },
	{ env = environment, clear_env = true, cwd = "/", text = true }
):wait()
assert(installed_result.code == 0, installed_result.stderr)
assert(read(home .. "/handoff"):find(engine .. "/apps/cli/run.lua", 1, true))
vim.fn.delete(home .. "/.local/bin/workstation")
-- Also retain public final-script chains and relative-target coverage.
vim.fn.mkdir(home .. "/.local/bin", "p")
assert(vim.uv.fs_symlink("hop", home .. "/.local/bin/workstation"))
assert(vim.uv.fs_symlink("../../clone-link", home .. "/.local/bin/hop"))
assert(vim.uv.fs_symlink(engine .. "/bin/workstation", home .. "/clone-link"))
local symlink_result = vim.system(
	{ home .. "/.local/bin/workstation", "status" },
	{ env = environment, clear_env = true, cwd = "/", text = true }
):wait()
assert(symlink_result.code == 0, symlink_result.stderr)
assert(read(home .. "/handoff"):find(engine .. "/apps/cli/run.lua", 1, true))
-- Unsupported architecture rejected before writes/downloads; Darwin branch is
-- simulated here, not a claim of macOS binary/runtime validation.
assert(launch({ TEST_ARCH = "aarch64" }, scratch .. "/unsupported").code ~= 0)
assert(not vim.uv.fs_stat(scratch .. "/unsupported"))
assert(launch({ TEST_OS = "Darwin", TEST_ARCH = "arm64" }, scratch .. "/darwin").code == 0)
-- Two true-cold processes serialize and share one verified download.
local concurrent = scratch .. "/concurrent"
local env = vim.tbl_extend(
	"force",
	environment,
	{ WORKSTATION_HOME = concurrent, TEST_SLOW = "yes", TEST_DOWNLOAD_LOG = scratch .. "/concurrent.log" }
)
local first = vim.system({ engine .. "/bin/workstation", "bootstrap" }, { env = env, clear_env = true, text = true })
local second = vim.system({ engine .. "/bin/workstation", "bootstrap" }, { env = env, clear_env = true, text = true })
assert(first:wait().code == 0 and second:wait().code == 0)
assert(read(scratch .. "/concurrent.log") == "download\n")
-- Canonical source SHA binding and strict record count reject modified input.
write(engine .. "/versions.json", read(engine .. "/versions.json") .. "\n")
assert(launch().code ~= 0)
checked({ vim.v.progpath, "-l", engine .. "/bootstrap/generate.lua" })
write(engine .. "/bootstrap/bootstrap.pins", read(engine .. "/bootstrap/bootstrap.pins") .. "extra|record\n")
assert(launch().code ~= 0)
vim.fn.delete(scratch, "rf")
print("bootstrap tests passed (cold shell, symlink, pin binding, cache, rollback, concurrency; simulated Darwin)")
