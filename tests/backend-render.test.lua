-- Real backend behavior tests with the trusted installed chezmoi binary.
-- The backend is passed in as an absolute path (like the frozen formatter):
-- its ACTUAL version is reported and is not the pinned lifecycle version.
-- These are file-only probes against isolated fixture homes: no downloads,
-- no live lifecycle, no native-platform acceptance.
local repository = vim.fn.getcwd()
local root = vim.fs.joinpath(repository, "workstation")
package.path = table.concat({
	vim.fs.joinpath(root, "?.lua"),
	vim.fs.joinpath(root, "?", "init.lua"),
	vim.fs.joinpath(root, "lua", "?.lua"),
	vim.fs.joinpath(root, "lua", "?", "init.lua"),
	package.path,
}, ";")

local commands = require("workstation.commands")
local paths = require("workstation.paths")
local provision = require("workstation.provision.recipes")
local provisioner = require("workstation.provisioner")
local source = require("workstation.source")
local state = require("workstation.state")

local backend = assert(arg[2], "run through .github/scripts/check.sh (trusted backend path required)")
assert(backend:sub(1, 1) == "/" and vim.fn.executable(backend) == 1, "backend path must be absolute and executable")
backend = assert(vim.uv.fs_realpath(backend))
local version = commands.capture(backend, { "--version" })
print("backend-render: " .. version)

local function install_backend()
	-- Model an already-bootstrapped backend at the engine's canonical path
	-- without copying tens of megabytes into the fixture home (the guarded
	-- check bounds every file at 4 MiB).
	local dest = paths.join(paths.local_dir, "opt", "chezmoi", "bin", "chezmoi")
	vim.fn.mkdir(vim.fs.dirname(dest), "p")
	assert(vim.uv.fs_symlink(backend, dest))
	return dest
end

-- Part 1: the REAL capability declarations through the full engine pipeline
-- against a fresh fixture home, then a populated and a repeated target.
local application = require("workstation.app").create()
local plan = source.plan(application)
assert(#plan.entries > 40, "expected the full migrated payload, got " .. #plan.entries)
assert(plan.profile and #plan.profile == 3, "composed profile is missing language intents")
install_backend()

-- Populate the exact legacy tombstones before the first apply: the backend
-- removes .chezmoiremove entries on first apply against fresh state (verified
-- identical against the retired centralized tree), while reappearance later is
-- the backend's interactive prompt path, not an engine concern.
local tombstones = require("workstation.provision.policy").legacy_removals
assert(#tombstones == 17, "expected seventeen legacy tombstones")
for _, removed in ipairs(tombstones) do
	local path = paths.join(paths.home, removed)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	vim.fn.writefile({ "legacy" }, path)
end
-- Unrelated user state that must survive untouched.
paths.write(paths.home .. "/.config/keep", "user state\n")
paths.write(paths.home .. "/.profile", "# user shell setup\n")

local generation = provisioner.apply(plan)
assert(not paths.exists(paths.home .. "/.local/share/lazyvim"), "tombstone survived first apply")
assert(paths.read(paths.home .. "/.config/keep") == "user state\n", "unrelated user state was touched")
assert(paths.read(paths.home .. "/.profile"):find("# user shell setup", 1, true), "user shell text lost")

local function assert_deployed()
	assert(paths.read(paths.home .. "/.node-version") == "24.19.0\n", "Node pin not deployed")
	assert(vim.uv.fs_readlink(paths.home .. "/.local/bin/nvim") == paths.home .. "/.local/opt/nvim/bin/nvim")
	assert(vim.uv.fs_readlink(paths.home .. "/.local/bin/go") == "../opt/go/bin/go")
	assert(vim.uv.fs_readlink(paths.home .. "/.config/tmux/tmux.conf") == "../../.tmux.conf")
	assert(bit.band(vim.uv.fs_stat(paths.home .. "/.pi/agent").mode, 4095) == 448, "private agent dir mode lost")
	assert(bit.band(vim.uv.fs_stat(paths.home .. "/.profile").mode, 4095) == 493, "shell file lost exec mode")
	assert(bit.band(vim.uv.fs_stat(paths.home .. "/.bashrc").mode, 4095) == 493, "shell file lost exec mode")
	local profile = paths.read(paths.home .. "/.config/nvim/lua/languages/profile.lua")
	local composed = assert(loadfile(paths.join(paths.home, ".config/nvim/lua/languages/profile.lua")))()
	assert(composed[1].id == "go" and composed[2].id == "typescript" and composed[3].id == "standard")
	assert(paths.read(paths.home .. "/.config/nvim/lua/languages/plugins/typescript.lua"):find("typescript", 1, true))
	local shell = paths.read(paths.home .. "/.profile")
	for _, marker in ipairs({
		"# chezmoi: managed user-local bin",
		"# chezmoi: load managed nvm",
		"# chezmoi: managed op env",
		"# chezmoi: managed ntfy notifier env",
	}) do
		assert(shell:find(marker, 1, true), "fragment missing from .profile: " .. marker)
	end
	local bashrc = paths.read(paths.home .. "/.bashrc")
	assert(
		bashrc:find("# chezmoi: managed user-local bin", 1, true)
			and bashrc:find("# chezmoi: load managed nvm", 1, true)
	)
	assert(not bashrc:find("op.env", 1, true), "op fragment leaked into .bashrc")
	return profile
end
local deployed_profile = assert_deployed()
-- Repository instructions can never deploy: no recipe targets AGENTS.md and
-- no ignore policy is needed to keep them out of generated source.
for _, entry in ipairs(plan.entries) do
	assert(not entry.target:find("AGENTS.md", 1, true), "instructions leaked into the plan: " .. entry.target)
end
assert(not vim.uv.fs_stat(paths.home .. "/.config/nvim/AGENTS.md"), "AGENTS.md deployed")
-- Package-owned payload deploys byte-for-byte from its owner.
local parity = {
	{ "workstation/packages/nvim/files/.config/nvim/init.lua", ".config/nvim/init.lua" },
	{ "workstation/packages/nvim/files/.config/nvim/lazy-lock.json", ".config/nvim/lazy-lock.json" },
	{ "workstation/packages/nvim/files/.config/nvim/lua/config/lazy.lua", ".config/nvim/lua/config/lazy.lua" },
	{ "workstation/packages/tmux/files/.tmux.conf", ".tmux.conf" },
	{ "workstation/packages/pi-skills/files/.pi/agent/skills/lazyvim/SKILL.md", ".pi/agent/skills/lazyvim/SKILL.md" },
	{ "workstation/packages/node/files/nvm.sh", ".config/shell/nvm.sh" },
}
for _, pair in ipairs(parity) do
	assert(
		paths.read(paths.join(paths.home, pair[2])) == paths.read(paths.join(repository, pair[1])),
		"deployed bytes differ from the owning package: " .. pair[2]
	)
end
print("backend-render: fresh target applied with package-owned byte parity")

-- Repeated apply is stable and keeps the identical generation.
local repeat_plan = source.plan(require("workstation.app").create())
assert(repeat_plan.generation == plan.generation, "desired state drifted between identical declarations")
provisioner.apply(repeat_plan)
assert(assert_deployed() == deployed_profile, "repeated apply changed deployed bytes")

-- R9: independent migration parity against frozen legacy evidence. The
-- baseline fixture was generated once from the retired centralized tree at
-- d674698e; runtime tests never touch Git history. Every one of the 44 legacy
-- files is accounted for: byte parity where the payload moved unchanged,
-- explicit permitted differences (updated skill guidance, generated profile),
-- or the non-deploying engine/instruction set verified through symlinks,
-- shell targets, tombstones and the AGENTS non-deployment proof.
local baseline = vim.json.decode(paths.read(paths.join(repository, "tests", "fixtures", "legacy-baseline.json")))
assert(#baseline.files == 44, "frozen baseline must account for all 44 legacy files")
assert(#baseline.tombstones == 17, "frozen baseline must keep 17 tombstones")

local permitted_differences = {
	["chezmoi/dot_pi/private_agent/skills/lazyvim/SKILL.md"] = "skill guidance updated for the generated-source layout",
}
local non_deploying = {
	["chezmoi/.chezmoiignore"] = "ignore policy superseded by recipe selection",
	["chezmoi/.chezmoiremove"] = "engine policy module owns the 17 tombstones",
	["chezmoi/AGENTS.md"] = "repository instructions can never deploy",
	["chezmoi/dot_config/nvim/AGENTS.md"] = "repository instructions can never deploy",
	["chezmoi/dot_config/tmux/symlink_tmux.conf"] = "declared link recipe",
	["chezmoi/dot_local/bin/symlink_go.tmpl"] = "declared link recipe",
	["chezmoi/dot_local/bin/symlink_nvim.tmpl"] = "declared link recipe",
	["chezmoi/modify_executable_dot_bashrc.tmpl"] = "composed by provision.shell",
	["chezmoi/modify_executable_dot_profile.tmpl"] = "composed by provision.shell",
	["chezmoi/modify_executable_dot_zshrc.tmpl"] = "composed by provision.shell",
}
local function legacy_disposition(legacy)
	if legacy == "chezmoi/dot_config/nvim/lua/languages/profile.lua" then
		return "profile"
	end
	if permitted_differences[legacy] then
		return "permitted"
	end
	if non_deploying[legacy] then
		return "non_deploying"
	end
	return "bytes"
end
local function legacy_target(legacy)
	local target = (
		legacy
			:gsub("^chezmoi/", "")
			:gsub("^dot_", ".")
			:gsub("/dot_", "/.")
			:gsub("/private_agent/", "/agent/")
			:gsub("^dot_pi/private_agent/", ".pi/agent/")
	)
	return target
end

local function assert_legacy_parity(phase)
	local checked = { bytes = 0, permitted = 0, non_deploying = 0, profile = 0 }
	for _, record in ipairs(baseline.files) do
		local disposition = legacy_disposition(record.legacy)
		checked[disposition] = checked[disposition] + 1
		local target = legacy_target(record.legacy)
		if disposition == "bytes" then
			local deployed = paths.read(paths.join(paths.home, target))
			assert(
				state.sha256(deployed) == record.sha256,
				phase .. ": deployed bytes differ from the frozen legacy baseline: " .. target
			)
		elseif disposition == "permitted" then
			-- The updated payload deploys exactly its owning package's bytes;
			-- the difference from the frozen legacy hash is the recorded one.
			local deployed = paths.read(paths.join(paths.home, target))
			assert(
				deployed ~= "" and state.sha256(deployed) ~= record.sha256,
				phase .. ": expected permitted difference missing for " .. target
			)
			assert(
				deployed:find("no checked%-in chezmoi", 1),
				phase .. ": permitted difference is not the documented skill update: " .. target
			)
		elseif disposition == "profile" then
			local deployed_profile = assert(loadfile(paths.join(paths.home, target)))()
			assert(#deployed_profile == #baseline.legacy_profile_semantics, phase .. ": profile entry count changed")
			for index, expected in ipairs(baseline.legacy_profile_semantics) do
				assert(
					vim.deep_equal(deployed_profile[index], expected),
					phase .. ": generated profile semantics differ from the frozen legacy profile at entry " .. index
				)
			end
		end
	end
	assert(checked.bytes == 32, phase .. ": byte-parity count drifted: " .. checked.bytes)
	assert(
		checked.permitted == 1 and checked.profile == 1 and checked.non_deploying == 10,
		phase .. ": disposition counts drifted"
	)
	for target, link in pairs(baseline.symlinks) do
		assert(vim.uv.fs_readlink(paths.join(paths.home, target)) == link, phase .. ": link drifted: " .. target)
	end
	assert(
		vim.uv.fs_readlink(paths.home .. "/.local/bin/nvim") == paths.home .. "/.local/opt/nvim/bin/nvim",
		phase .. ": nvim link drifted"
	)
	for target, markers in pairs(baseline.shell_targets) do
		local contents = paths.read(paths.join(paths.home, target))
		for _, marker in ipairs(markers) do
			assert(contents:find(marker, 1, true), phase .. ": shell marker missing from " .. target .. ": " .. marker)
		end
		local mode = string.format("%o", bit.band(vim.uv.fs_stat(paths.join(paths.home, target)).mode, 4095))
		assert(mode == baseline.shell_modes.mode, phase .. ": shell mode drifted for " .. target)
	end
	for _, directory in ipairs(baseline.private_directories) do
		assert(
			bit.band(vim.uv.fs_stat(paths.join(paths.home, directory)).mode, 4095) == 448,
			phase .. ": private directory mode drifted for " .. directory
		)
	end
	assert(
		paths.read(paths.home .. "/.node-version"):gsub("\n$", "") == baseline.node_version,
		phase .. ": node pin drifted"
	)
	for _, removed in ipairs(baseline.tombstones) do
		assert(vim.uv.fs_lstat(paths.join(paths.home, removed)) == nil, phase .. ": tombstone survived: " .. removed)
	end
	assert(not vim.uv.fs_stat(paths.home .. "/.config/nvim/AGENTS.md"), phase .. ": instructions deployed")
	assert(paths.read(paths.home .. "/.config/keep") == "user state\n", phase .. ": unrelated user state touched")
	return checked
end
assert_legacy_parity("fresh")

-- Repeated apply is byte-stable across every deployed target.
local function deployed_snapshot()
	local snapshot = {}
	for _, record in ipairs(baseline.files) do
		local disposition = legacy_disposition(record.legacy)
		if disposition == "bytes" or disposition == "permitted" then
			local target = legacy_target(record.legacy)
			snapshot[target] = paths.read(paths.join(paths.home, target))
		end
	end
	for target in pairs(baseline.shell_targets) do
		snapshot[target] = paths.read(paths.join(paths.home, target))
	end
	snapshot[".config/nvim/lua/languages/profile.lua"] =
		paths.read(paths.home .. "/.config/nvim/lua/languages/profile.lua")
	return snapshot
end
local before_repeat = deployed_snapshot()
provisioner.apply(source.plan(require("workstation.app").create()))
assert(vim.deep_equal(deployed_snapshot(), before_repeat), "repeated apply changed deployed bytes")
assert_legacy_parity("repeated")
print("backend-render: independent legacy parity holds on fresh and repeated targets")

-- Populated target with an existing DIFFERING unrecorded owned-path file: the
-- engine must conflict before any backend mutation, leave every owned target
-- untouched, and converge only after explicit fixture-only operator recovery.
paths.write(paths.home .. "/.config/nvim/init.lua", "-- operator-local nvim config\n")
local guard_snapshot = deployed_snapshot()
local failed_apply, failure = pcall(function()
	provisioner.apply(source.plan(require("workstation.app").create()))
end)
assert(not failed_apply, "differing unrecorded owned-path file was overwritten")
assert(
	tostring(failure):find("target changed since the last successful apply", 1, true),
	"unexpected failure: " .. tostring(failure)
)
assert(vim.deep_equal(deployed_snapshot(), guard_snapshot), "conflicting apply partially mutated owned targets")
assert(
	paths.read(paths.home .. "/.config/nvim/init.lua") == "-- operator-local nvim config\n",
	"conflicting apply touched the unrecorded file"
)
-- Fixture-only operator resolution: restore the expected source bytes, then
-- the engine converges and full legacy parity holds again.
paths.write(
	paths.home .. "/.config/nvim/init.lua",
	paths.read(paths.join(repository, "workstation/packages/nvim/files/.config/nvim/init.lua"))
)
provisioner.apply(source.plan(require("workstation.app").create()))
assert_legacy_parity("after-recovery")
print("backend-render: populated target conflicts safely and converges after explicit recovery")

-- Part 2: native modifier versus run-script exclusion with the trusted
-- backend, using a synthetic generated source. This is the evidence that
-- `--exclude scripts` skips run scripts while still executing modify scripts.
local scratch = vim.fn.tempname()
vim.fn.mkdir(scratch, "p")
local source_tree = paths.join(scratch, "source")
local destination = paths.join(scratch, "home")
vim.fn.mkdir(destination, "p")
paths.write(
	paths.join(source_tree, "modify_executable_dot_envrc"),
	[[#!/usr/bin/env sh
set -eu
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT HUP INT TERM
cat >"$tmp"
cat "$tmp"
if ! grep -Fqx '# probe: modifier' "$tmp"; then
  printf '\n%s\n%s\n' '# probe: modifier' 'export PROBE=modifier-ran' >>"$tmp"
fi
cat "$tmp" >/dev/null
cat "$tmp"
]]
)
paths.write(
	paths.join(source_tree, "run_once_script-marker"),
	"#!/bin/sh\nprintf 'script-ran\\n' > " .. scratch .. "/script-marker\n"
)
local function backend_apply(exclude)
	local argv = { backend, "--source", source_tree, "--destination", destination, "apply" }
	if exclude then
		table.insert(argv, "--exclude")
		table.insert(argv, "scripts")
	end
	local result = vim.system(argv, { text = true }):wait()
	assert(result.code == 0, result.stdout .. result.stderr)
end
backend_apply(true)
assert(not paths.exists(paths.join(scratch, "script-marker")), "--exclude scripts did not skip the run script")
local envrc = paths.read(destination .. "/.envrc")
assert(
	envrc:find("# probe: modifier", 1, true) and envrc:find("PROBE=modifier-ran", 1, true),
	"native modifier was excluded"
)
print("backend-render: --exclude scripts skips run scripts, native modifiers still run")
backend_apply(false)
assert(
	paths.read(paths.join(scratch, "script-marker")) == "script-ran\n",
	"run script did not execute without exclusion"
)

-- Part 3: native private/executable FILE permissions are faithful chezmoi
-- source attributes, not directory-only: bounded proof with the same trusted
-- backend that private files deploy 0600 and private+executable 0755.
do
	local mode_tree = paths.join(scratch, "mode-source")
	local mode_home = paths.join(scratch, "mode-home")
	vim.fn.mkdir(mode_home, "p")
	paths.write(paths.join(mode_tree, "private_dot_secret"), "private payload\n")
	paths.write(paths.join(mode_tree, "private_executable_dot_tool"), "#!/bin/sh\nexit 0\n")
	paths.write(paths.join(mode_tree, "executable_dot_plain"), "#!/bin/sh\nexit 0\n")
	local result = vim.system({ backend, "--source", mode_tree, "--destination", mode_home, "apply" }, { text = true })
		:wait()
	assert(result.code == 0, result.stderr)
	local function mode_of(name)
		return bit.band(assert(vim.uv.fs_lstat(paths.join(mode_home, name))).mode, 4095)
	end
	assert(mode_of(".secret") == 384, "private file did not deploy 0600")
	assert(mode_of(".tool") == 448, "private executable file did not deploy 0700")
	assert(mode_of(".plain") == 493, "executable file did not deploy 0755")
	assert(paths.read(paths.join(mode_home, ".secret")) == "private payload\n")
	-- the provider encodes exactly these native names for file recipes
	local provider = require("workstation.provision.chezmoi")
	local private_file = provider.recipe({ target = ".secret", kind = "file", content = "x\n", private = true })
	assert(provider.source_name(private_file.spec) == "private_dot_secret")
	local private_executable = provider.recipe({
		target = ".tool",
		kind = "file",
		content = "x\n",
		private = true,
		executable = true,
	})
	assert(provider.source_name(private_executable.spec) == "private_executable_dot_tool")
	assert(provider.entry_mode(private_file.spec) == 384 and provider.entry_mode(private_executable.spec) == 448)
end
print("backend-render: private and executable file modes are native source attributes")

-- Part 4: template recipes are rendered by the backend itself.
local template_tree = paths.join(scratch, "template-source")
paths.write(
	paths.join(template_tree, "dot_tmpl.tmpl"),
	"os={{ .chezmoi.os }} arch={{ .chezmoi.arch }} home={{ .chezmoi.homeDir }}\n"
)
local template_destination = paths.join(scratch, "template-home")
vim.fn.mkdir(template_destination, "p")
local result = vim.system({
	backend,
	"--source",
	template_tree,
	"--destination",
	template_destination,
	"apply",
}, { text = true }):wait()
assert(result.code == 0, result.stderr)
local rendered = paths.read(template_destination .. "/.tmpl")
local uname = vim.uv.os_uname()
assert(rendered:find("os=" .. uname.sysname:lower(), 1, true), "template did not render the OS: " .. rendered)
-- .chezmoi.homeDir follows the backend process home; the engine keeps
-- destination and target home identical, so generations stay consistent.
assert(rendered:find("home=" .. vim.env.HOME, 1, true), "template did not render the home: " .. rendered)
-- The engine treats backend-rendered targets as unverifiable from the recipe:
-- first adoption of existing unrecorded rendered state conflicts (journal.test).
print("backend-render: template recipes render through the backend")

print(
	"backend-render tests passed (real "
		.. version
		.. "; fresh/populated/repeat parity, modes/links/private, tombstones, modifier vs script exclusion, templates)"
)
