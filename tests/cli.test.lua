local repository = vim.fn.getcwd()
local scratch = vim.fn.tempname()
vim.env.WORKSTATION_HOME = scratch .. "/target"
for _, key in ipairs({
	"XDG_CONFIG_HOME",
	"XDG_DATA_HOME",
	"XDG_STATE_HOME",
	"XDG_CACHE_HOME",
	"XDG_RUNTIME_DIR",
	"WORKSTATION_CACHE",
}) do
	vim.env[key] = scratch .. "/ambient/" .. key
end
package.path = repository .. "/workstation/lua/?.lua;" .. repository .. "/workstation/?.lua;" .. package.path
local paths = require("workstation.paths")
for _, key in ipairs({
	"HOME",
	"USERPROFILE",
	"XDG_CONFIG_HOME",
	"XDG_DATA_HOME",
	"XDG_STATE_HOME",
	"XDG_CACHE_HOME",
	"XDG_RUNTIME_DIR",
	"WORKSTATION_CACHE",
	"TMPDIR",
}) do
	assert(vim.env[key]:sub(1, #paths.home) == paths.home, key .. " escaped target")
end
local commands = require("workstation.commands")
local function executable(path, body)
	paths.write(path, "#!/bin/sh\nset -eu\n" .. body)
	assert(vim.uv.fs_chmod(path, 448))
end
-- First apply had no .node-version; refreshing runtime must not retain nil.
local versions = require("workstation.versions")
assert(versions.node == nil)
vim.fn.mkdir(scratch .. "/no-node-bin", "p")
assert(vim.uv.fs_symlink(vim.fn.exepath("sh"), scratch .. "/no-node-bin/sh"))
vim.env.PATH = scratch .. "/no-node-bin"
local adapter = require("workstation.platforms.unix").new({ name = "linux" })
adapter.configure_runtime()
versions.node = "99.1.0"
paths.write(paths.home .. "/.node-version", versions.node)
local bin = paths.local_dir .. "/opt/nvm/versions/node/v" .. versions.node .. "/bin"
executable(bin .. "/node", "printf 'pinned-node:%s\\n' \"$1\"\n")
paths.write(bin .. "/npm", "#!/usr/bin/env node\n")
vim.uv.fs_chmod(bin .. "/npm", 448)
adapter.configure_runtime()
assert(commands.capture(bin .. "/npm") == "pinned-node:" .. bin .. "/npm", "shebang did not resolve managed Node")
local current_path = vim.env.PATH
adapter.configure_runtime()
assert(vim.env.PATH == current_path, "refresh duplicated PATH")

-- Retirement always stubs the service primitive and OS account identity; it
-- never reaches the real service manager, even for simulated host ownership.
local retire = require("workstation.retire")
local execute, passwd = commands.execute, vim.uv.os_get_passwd
local calls = {}
commands.execute = function(command, args)
	table.insert(calls, command .. " " .. table.concat(args, " "))
end
vim.uv.os_get_passwd = function()
	return { homedir = scratch .. "/host", uid = vim.uv.getuid() }
end
local context = { paths = paths, platform = { name = "linux" } }
assert(retire.run(context) == false and #calls == 0)
vim.uv.os_get_passwd = function()
	return { homedir = paths.home, uid = vim.uv.getuid() }
end
assert(retire.run(context) == false and #calls == 0, "missing unit marked retired")
local unit = paths.home .. "/.config/systemd/user/workstation-subagents.service"
paths.write(unit, "unowned service")
assert(not pcall(retire.run, context) and #calls == 0)
paths.write(
	unit,
	"Description=Workstation GoAkt subagents daemon\nExecStart=%h/.local/bin/workstation-subagents --config %t/ws-subagents/config.toml\n"
)
vim.uv.fs_chmod(unit, 438)
assert(not pcall(retire.run, context) and #calls == 0, "writable unit accepted")
vim.uv.fs_chmod(unit, 384)
commands.execute = function()
	error("stubbed service failure")
end
assert(not pcall(retire.run, context))
local marker = vim.env.WORKSTATION_CACHE .. "/retire/subagents-service"
assert(not paths.exists(marker), "failed retirement recorded success")
commands.execute = function(command, args)
	table.insert(calls, command .. " " .. table.concat(args, " "))
end
assert(retire.run(context) and #calls == 2 and paths.exists(marker))
assert(retire.run(context) and #calls == 2, "successful retirement repeated")
vim.fn.delete(marker)
context.platform.name = "darwin"
paths.write(
	paths.home .. "/Library/LaunchAgents/com.workstation.subagents.plist",
	"<key>Label</key><string>com.workstation.subagents</string><string>"
		.. paths.home
		.. "/.local/bin/workstation-subagents</string>"
)
assert(retire.run(context) and calls[3]:find("launchctl bootout gui/", 1, true))
commands.execute, vim.uv.os_get_passwd = execute, passwd

-- Real checked argv children, but fake git and launcher in a tiny copied engine.
local fixture = scratch .. "/repo/workstation"
local run = fixture .. "/apps/cli/run.lua"
paths.write(run, paths.read(repository .. "/workstation/apps/cli/run.lua"))
local log = scratch .. "/update.log"
vim.env.TEST_LOG = log
executable(scratch .. "/bin/git", 'printf "git:%s\\n" "$*" >> "$TEST_LOG"\n[ "${TEST_FAIL:-}" != git ]\n')
executable(fixture .. "/bin/workstation", 'printf "%s\\n" "$1" >> "$TEST_LOG"\n[ "${TEST_FAIL:-}" != "$1" ]\n')
vim.env.PATH = scratch .. "/bin:" .. vim.env.PATH
local original_app, original_provisioner = package.loaded["workstation.app"], package.loaded["workstation.provisioner"]
package.loaded["workstation.app"] = {
	create = function()
		return { context = context }
	end,
}
package.loaded["workstation.provisioner"] = {
	repo_root = function()
		return scratch .. "/repo"
	end,
}
local original_arg = arg
arg = { "update" }
for _, failure in ipairs({ "", "git", "apply", "sync", "verify" }) do
	paths.write(log, "")
	vim.env.TEST_FAIL = failure
	local ok = pcall(dofile, run)
	assert(ok == (failure == ""), "update status mismatch for " .. failure)
	local lines = vim.split(vim.trim(paths.read(log)), "\n")
	local expected = failure == "git" and 1 or failure == "apply" and 2 or failure == "sync" and 3 or 4
	assert(#lines == expected, "update did not stop at first failure")
	assert(lines[1] == "git:-C " .. scratch .. "/repo pull --ff-only")
	for index = 2, #lines do
		assert(lines[index] == ({ "apply", "sync", "verify" })[index - 1])
	end
end
arg = original_arg
package.loaded["workstation.app"], package.loaded["workstation.provisioner"] = original_app, original_provisioner
-- Exercise the actual apply refresh seam, not only the adapter in isolation.
local original_retire = package.loaded["workstation.retire"]
versions.node = nil
vim.fn.delete(paths.home .. "/.node-version")
adapter.configure_runtime()
local setup_ran = false
package.loaded["workstation.retire"] = { run = function() end }
package.loaded["workstation.provisioner"] = {
	apply = function()
		paths.write(paths.home .. "/.node-version", "99.1.0")
	end,
}
package.loaded["workstation.app"] = {
	create = function()
		return {
			context = { paths = paths, versions = versions, platform = adapter },
			runner = {
				run = function(_, step)
					assert(step == "setup" and versions.node == "99.1.0")
					assert(commands.capture(bin .. "/npm") == "pinned-node:" .. bin .. "/npm")
					setup_ran = true
				end,
			},
		}
	end,
}
arg = { "apply" }
dofile(run)
assert(setup_ran)
arg = original_arg
package.loaded["workstation.app"], package.loaded["workstation.provisioner"], package.loaded["workstation.retire"] =
	original_app, original_provisioner, original_retire
-- Backend provisioning is engine-owned and uses canonical exact metadata; no
-- actual backend download/install in this test.
local provision = require("workstation.provision")
local create = provision.create
local requested
provision.create = function()
	return {
		archive = function(spec)
			requested = spec
		end,
	}
end
require("workstation.provisioner").ensure_backend()
provision.create = create
local asset = vim.uv.os_uname().sysname == "Darwin" and "darwin_arm64" or "linux_x86_64"
assert(requested.sha256 == versions["chezmoi_" .. asset .. "_sha256"])
assert(requested.url == versions["chezmoi_" .. asset .. "_url"]:gsub("{V}", versions.chezmoi))
assert(
	requested.dest == paths.local_dir .. "/opt/chezmoi/bin/chezmoi"
		and requested.inner_path == "chezmoi"
		and requested.format == "tar"
)
vim.fn.delete(scratch, "rf")
print(
	"CLI tests passed (confinement, first Node PATH/apply refresh, stubbed retirement/backend, checked update first-error stop)"
)
