local repository = vim.fn.getcwd()
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
local clone = scratch .. "/source"
local bin = scratch .. "/prerequisites"
for _, name in ipairs({ "sh", "env", "dirname", "basename", "mkdir", "mktemp", "ln", "cp", "cat", "find" }) do
	vim.fn.mkdir(bin, "p")
	assert(vim.uv.fs_symlink(assert(vim.fn.exepath(name)), bin .. "/" .. name))
end
write(bin .. "/git", "#!/bin/sh\n[ \"$*\" = 'diff --check' ]\n", true)
write(bin .. "/shellcheck", '#!/bin/sh\n[ "$(cat "$PWD/failure")" != shellcheck ] || exit 43\n', true)
-- Only this copied fixture changes the production prerequisite PATH. This is
-- not an ambient-runtime bootstrap claim or a production test-mode switch.
local harness = read(repository .. "/.github/scripts/test-apply.sh")
harness = harness:gsub("PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "PATH=" .. bin)
write(clone .. "/.github/scripts/test-apply.sh", harness, true)
write(clone .. "/.github/scripts/check.sh", read(repository .. "/.github/scripts/check.sh"))
write(clone .. "/.github/scripts/test-home.sh", read(repository .. "/.github/scripts/test-home.sh"))
write(clone .. "/.github/scripts/syntax.lua", "")
for name in vim.fs.dir(repository .. "/tests") do
	if name:match("%.test.lua$") then
		write(clone .. "/tests/" .. name, "")
	end
end
write(clone .. "/chezmoi/.keep", "")
write(
	clone .. "/fixture-nvim",
	[[#!/bin/sh
set -eu
parent=${0%/.local/opt/nvim/bin/nvim}
printf 'nvim:%s\n' "$*" >> "$parent/events"
[ "$(cat "$parent/../failure")" != tests ] || exit 41
]],
	true
)
write(
	clone .. "/fixture-stylua",
	[[#!/bin/sh
set -eu
parent=${0%/.local/share/nvim/mason/bin/stylua}
printf 'stylua\n' >> "$parent/events"
[ "$(cat "$parent/../failure")" != format ] || exit 42
]],
	true
)
write(
	clone .. "/workstation/bin/workstation",
	[[#!/bin/sh
set -eu
for value in "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" "$WORKSTATION_CACHE" "$TMPDIR"; do
 case "$value" in "$HOME/"*) ;; *) exit 90 ;; esac
done
[ "${ANTHROPIC_API_KEY-unset}" = unset ]
[ "${SSH_AUTH_SOCK-unset}" = unset ]
[ "${DBUS_SESSION_BUS_ADDRESS-unset}" = unset ]
[ "${PI_CODING_AGENT_DIR-unset}" = unset ]
[ "${BASH_ENV-unset}" = unset ]
[ "${ENV-unset}" = unset ]
[ "${OP_SERVICE_ACCOUNT_TOKEN-unset}" = unset ]
[ "${NPM_CONFIG_USERCONFIG-unset}" = unset ]
[ "${GIT_CONFIG_COUNT-unset}" = unset ]
[ "${WORKSTATION_SESSION_CAPTURED-unset}" = unset ]
[ "$GIT_CONFIG_NOSYSTEM" = 1 ]
printf '%s\n' "$1" >> "$HOME/events"
[ "$(cat "$HOME/../failure")" != "$1" ] || exit 37
if [ "$1" = bootstrap ]; then
 ! command -v node
 ! command -v nvim
 printf 'no-ambient-node-or-nvim\n' >> "$HOME/events"
 mkdir -p "$HOME/.local/bin" "$HOME/.local/opt/nvim/bin" "$HOME/.local/share/nvim/mason/bin"
 cp fixture-nvim "$HOME/.local/opt/nvim/bin/nvim"
 cp fixture-stylua "$HOME/.local/share/nvim/mason/bin/stylua"
 ln -s "$PWD/workstation/bin/workstation" "$HOME/.local/bin/workstation"
fi
]],
	true
)
local ambient = scratch .. "/ambient"
vim.fn.mkdir(ambient, "p")
write(ambient .. "/.profile", "exit 91")
local env = { HOME = ambient, PATH = "/usr/bin:/bin" }
for _, key in ipairs({
	"ANTHROPIC_API_KEY",
	"SSH_AUTH_SOCK",
	"DBUS_SESSION_BUS_ADDRESS",
	"PI_CODING_AGENT_DIR",
	"BASH_ENV",
	"ENV",
	"OP_SERVICE_ACCOUNT_TOKEN",
	"NPM_CONFIG_USERCONFIG",
	"GIT_CONFIG_COUNT",
	"WORKSTATION_SESSION_CAPTURED",
}) do
	env[key] = "fixture-poison-not-a-credential"
end
local function run(target)
	return vim.system({ clone .. "/.github/scripts/test-apply.sh", target }, {
		env = env,
		clear_env = true,
		cwd = "/",
		text = true,
	}):wait()
end
for _, failure in ipairs({ "none", "bootstrap", "apply", "sync", "tests", "format", "shellcheck", "verify" }) do
	local parent = scratch .. "/" .. failure
	write(parent .. "/failure", failure)
	write(clone .. "/failure", failure)
	local target = parent .. "/home"
	local result = run(target)
	local expected = failure == "none" and 0
		or failure == "tests" and 41
		or failure == "format" and 42
		or failure == "shellcheck" and 43
		or 37
	assert(result.code == expected, failure .. ": " .. result.code .. " " .. result.stderr)
	local events = read(target .. "/events")
	assert(events:match("^bootstrap"))
	if failure == "bootstrap" then
		assert(events == "bootstrap" and not vim.uv.fs_lstat(target .. "/.local/bin/workstation"))
	else
		assert(events:find("no-ambient-node-or-nvim", 1, true))
	end
	if failure == "apply" or failure == "sync" then
		assert(not events:find("nvim:", 1, true))
	elseif failure == "tests" then
		assert(not vim.list_contains(vim.split(events, "\n", { plain = true }), "stylua"))
	elseif failure == "format" or failure == "shellcheck" then
		assert(not events:find("verify", 1, true))
	elseif failure == "none" or failure == "verify" then
		assert(events:find("apply\nsync\nnvim:", 1, true))
		for name in vim.fs.dir(repository .. "/tests") do
			if name:match("%.test.lua$") then
				assert(events:find("tests/" .. name, 1, true), "harness omitted " .. name)
			end
		end
		assert(events:find("stylua\nverify", 1, true))
	end
	assert(run(target).code ~= 0 and read(target .. "/events") == events, "reused destination")
end
for _, target in ipairs({ "/", ambient, ambient .. "/child", clone, clone .. "/child", scratch, "relative" }) do
	assert(run(target).code ~= 0, "dangerous path accepted: " .. target)
end
local empty = scratch .. "/empty"
vim.fn.mkdir(empty, "p")
assert(run(empty).code ~= 0)
assert(vim.uv.fs_symlink(empty, scratch .. "/link"))
assert(run(scratch .. "/link").code ~= 0)
assert(not vim.uv.fs_stat(empty .. "/events"))
-- An invalid later shell must be checked in its own process, not silently
-- ignored as an extra filename to a single sh -n invocation.
write(clone .. "/.github/scripts/z-invalid.sh", "#!/bin/sh\n(\n")
write(scratch .. "/syntax-failure/failure", "none")
write(clone .. "/failure", "none")
local syntax_failure = run(scratch .. "/syntax-failure/home")
assert(syntax_failure.code == 2, syntax_failure.stderr)
assert(not read(scratch .. "/syntax-failure/home/events"):find("verify", 1, true))
vim.fn.delete(scratch, "rf")
print(
	"harness tests passed (copied source, cold controlled PATH, clean environment, guarded destinations, first-failure exact exits)"
)
