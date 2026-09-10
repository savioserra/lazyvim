-- Engine state, precondition, journal and reconciliation tests through the
-- REAL collector/assembler/provisioner paths. The backend child is a fake
-- desired-state applier (plain filesystem writes plus execution of the real
-- generated modify programs); actual chezmoi semantics are proven separately
-- in backend-render.test.lua.
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

local function assert_fails(pattern, callback)
	local ok, failure = pcall(callback)
	assert(not ok, "expected operation to fail")
	assert(
		tostring(failure):find(pattern, 1, true),
		("expected failure containing %q, got %q"):format(pattern, failure)
	)
end

local package_root = vim.fn.tempname()
vim.fn.mkdir(package_root, "p")
paths.write(paths.join(package_root, "payload"), "payload-v1\n")

local function declarations(options)
	options = options or {}
	local contributes = {
		provision.chezmoi({ target = ".state/file-a", kind = "file", asset = "payload" }),
		provision.chezmoi({ target = ".state/link-a", kind = "symlink", to = "../opt/tool" }),
		provision.chezmoi({ target = ".state/dir", kind = "directory", private = true }),
	}
	if not options.without_modify then
		table.insert(
			contributes,
			provision.shell({
				target = ".statenv",
				fragment = { id = "frag-a", order = 10, marker = "# test: frag-a", body = "echo a", order = 10 },
			})
		)
		table.insert(
			contributes,
			provision.shell({
				target = ".statenv",
				fragment = { id = "frag-b", order = 20, marker = "# test: frag-b", body = "echo b", order = 20 },
			})
		)
	end
	if options.extra_file then
		table.insert(
			contributes,
			provision.chezmoi({
				target = ".state/file-b",
				kind = "file",
				content = "file-b-v1\n",
			})
		)
	end
	return contributes
end

local function application_for(contributes)
	return {
		context = {},
		graph = { ordered = { { id = "test-package", contributes = contributes } } },
		packages_roots = { test_package = "unused", ["test-package"] = package_root },
	}
end

-- Fake backend: applies the plan's desired state directly (files, modes,
-- links) and executes the real generated modify programs through sh.
local applied_plans, fail_next = {}, false
local real_execute = commands.execute
commands.execute = function(executable, argv)
	assert(executable:sub(-#"chezmoi") == "chezmoi", "unexpected child executed: " .. executable)
	assert(argv[1] == "--source" and argv[5] == "apply", "unexpected backend invocation")
	local generation = argv[2]
	local destination = argv[4]
	assert(destination == paths.home, "backend destination escaped the target home")
	if fail_next then
		fail_next = false
		error("fake backend apply failure")
	end
	local plan = assert(applied_plans[generation:match("([^/]+)$")], "backend received an unpublished generation")
	for _, entry in ipairs(plan.entries) do
		local target = paths.join(paths.home, entry.target)
		if entry.operation == "directory" then
			vim.fn.mkdir(target, "p")
			vim.uv.fs_chmod(target, entry.mode or 493)
		elseif entry.operation == "symlink" then
			vim.fn.delete(target, "rf")
			assert(vim.uv.fs_symlink(entry.link, target))
		elseif entry.operation == "modify" then
			local current = ""
			local file = io.open(target, "rb")
			if file then
				current = file:read("*a")
				file:close()
			end
			local script = paths.join(generation, entry.source_name)
			local result = vim.system({ "sh", script }, { stdin = current, text = true }):wait()
			assert(result.code == 0, "generated modify program failed: " .. (result.stderr or ""))
			paths.write(target, result.stdout)
			vim.uv.fs_chmod(target, entry.mode or 493)
		else
			paths.write(target, entry.bytes)
			vim.uv.fs_chmod(target, entry.mode or 420)
		end
	end
	local removed = vim.split(vim.trim(paths.read(paths.join(generation, ".chezmoiremove"))), "\n")
	for _, removal in ipairs(removed) do
		vim.fn.delete(paths.join(paths.home, removal), "rf")
	end
end

local function plan_for(options)
	local plan = source.plan(application_for(declarations(options)))
	applied_plans[plan.generation] = plan
	return plan
end

local function apply_for(options)
	return provisioner.apply(plan_for(options))
end

-- First apply adopts an absent target, records fingerprints and fragments.
local generation = apply_for({})
assert(vim.uv.fs_stat(paths.join(paths.home, ".state/file-a")), "file was not applied")
local generation_id = generation:match("([^/]+)$")
assert(vim.uv.fs_readlink(paths.join(paths.home, ".state/link-a")) == "../opt/tool")
assert(bit.band(vim.uv.fs_stat(paths.join(paths.home, ".state/dir")).mode, 4095) == 448, "private dir mode lost")
local statenv = paths.read(paths.home .. "/.statenv")
assert(statenv:find("# test: frag-a", 1, true) and statenv:find("# test: frag-b", 1, true))
local journal = state.applied_record()
assert(journal.generation == generation_id and journal.targets[".state/file-a"].sha256)
assert(journal.fragments[".statenv"] and #journal.fragments[".statenv"] == 2)
assert(not paths.exists(paths.join(state.root(), "apply.lock")), "apply retained the lock")
print("first apply recorded")

-- Repeated identical apply is a deduplicated no-op.
assert(apply_for({}) == generation)

-- Intervening home edit conflicts before any mutation.
paths.write(paths.home .. "/.state/file-a", "edited\n")
assert_fails("target changed since the last successful apply", function()
	apply_for({})
end)
assert(paths.read(paths.home .. "/.state/file-a") == "edited\n", "conflict mutated the target")
-- Restoring the recorded bytes is an explicit operator action; afterwards
-- applies converge again.
paths.write(paths.home .. "/.state/file-a", "payload-v1\n")

-- Plans that add one target keep every other owned target declared so
-- reconciliation stays meaningful.
local function plan_with(extra, options)
	local contributes = declarations(options)
	vim.list_extend(contributes, extra)
	local plan = source.plan(application_for(contributes))
	applied_plans[plan.generation] = plan
	return plan
end

-- An unrecorded differing whole file conflicts on first adoption.
paths.write(paths.home .. "/.state/adopt", "user data\n")
local adoption_plan = plan_with({
	provision.chezmoi({ target = ".state/adopt", kind = "file", content = "managed\n" }),
})
assert_fails("first adoption", function()
	provisioner.apply(adoption_plan)
end)
assert(paths.read(paths.home .. "/.state/adopt") == "user data\n", "first adoption overwrote user data")
-- an identical unrecorded file is adopted safely
paths.write(paths.home .. "/.state/adopt", "managed\n")
provisioner.apply(adoption_plan)
assert(state.applied_record().targets[".state/adopt"], "identical adoption was not recorded")

-- A differing symlink and a non-link target at a link destination conflict.
local link_plan = plan_with({
	provision.chezmoi({ target = ".state/other-link", kind = "symlink", to = "../opt/tool" }),
})
assert(vim.uv.fs_symlink("/somewhere/else", paths.home .. "/.state/other-link"))
assert_fails("first adoption", function()
	provisioner.apply(link_plan)
end)
vim.fn.delete(paths.home .. "/.state/other-link")
paths.write(paths.home .. "/.state/other-link", "regular\n")
assert_fails("first adoption", function()
	provisioner.apply(link_plan)
end)

-- Backend-rendered (template) targets never adopt unrecorded existing state.
local template_plan = plan_with({
	provision.chezmoi({ target = ".state/rendered", kind = "file", content = "{{ .chezmoi.os }}\n", template = true }),
})
paths.write(paths.home .. "/.state/rendered", "existing\n")
assert_fails("backend-rendered target exists without an owned record", function()
	provisioner.apply(template_plan)
end)

-- Failures preserve pending and failed evidence; retrying the same generation
-- converges idempotently instead of requiring operator recovery.
local before_failure = state.applied_record().generation
local new_plan = plan_for({ extra_file = true })
fail_next = true
assert_fails("fake backend apply failure", function()
	provisioner.apply(new_plan)
end)
assert(#state.pending_records() == 1, "pending attempt was not recorded")
local failed_seen = false
for name in vim.fs.dir(paths.join(state.journal_root(), "failed")) do
	failed_seen = failed_seen or name:find(".json$") ~= nil
end
assert(failed_seen, "failed attempt evidence was not retained")
assert(state.applied_record().generation == before_failure, "failed apply advanced last-applied")
provisioner.apply(new_plan)
assert(#state.pending_records() == 0, "successful retry kept the pending record")
assert(state.applied_record().targets[".state/file-b"], "retry did not converge")
assert(paths.read(paths.home .. "/.state/file-b") == "file-b-v1\n")

-- Exclusive leaf retirement: disappearing recipe with a matching fingerprint
-- generates a precise removal; an edited leaf conflicts.
local after_retire = plan_for({})
provisioner.apply(after_retire)
assert(state.applied_record().targets[".state/file-b"] == nil, "retired target stayed owned")
assert(not paths.exists(paths.home .. "/.state/file-b"), "retired leaf was not removed")
-- reintroduce, apply, then edit before retirement
paths.write(paths.home .. "/.state/file-b", "file-b-v1\n")
provisioner.apply(plan_for({ extra_file = true }))
assert(state.applied_record().targets[".state/file-b"])
paths.write(paths.home .. "/.state/file-b", "edited-before-retirement\n")
assert_fails("retiring .state/file-b failed", function()
	provisioner.apply(plan_for({}))
end)
assert(paths.read(paths.home .. "/.state/file-b") == "edited-before-retirement\n")
paths.write(paths.home .. "/.state/file-b", "file-b-v1\n")
provisioner.apply(plan_for({}))

-- Fragment retirement recomposes the shared file and removes only the exact
-- known block; user text and the other owner's fragment survive.
paths.write(paths.home .. "/.statenv", "# user keeps this\n" .. paths.read(paths.home .. "/.statenv"))
local single = source.plan(application_for({
	provision.chezmoi({ target = ".state/file-a", kind = "file", asset = "payload" }),
	provision.chezmoi({ target = ".state/link-a", kind = "symlink", to = "../opt/tool" }),
	provision.chezmoi({ target = ".state/dir", kind = "directory", private = true }),
	provision.shell({
		target = ".statenv",
		fragment = { id = "frag-b", marker = "# test: frag-b", body = "echo b", order = 20 },
	}),
}))
applied_plans[single.generation] = single
provisioner.apply(single)
local recomposed = paths.read(paths.home .. "/.statenv")
assert(not recomposed:find("# test: frag-a", 1, true), "retired fragment block survived")
assert(recomposed:find("# test: frag-b", 1, true) and recomposed:find("# user keeps this", 1, true))
assert(state.applied_record().fragments[".statenv"] and #state.applied_record().fragments[".statenv"] == 1)
-- removing the LAST fragment still strips its block and never deletes the file
local none = source.plan(application_for({
	provision.chezmoi({ target = ".state/file-a", kind = "file", asset = "payload" }),
	provision.chezmoi({ target = ".state/link-a", kind = "symlink", to = "../opt/tool" }),
	provision.chezmoi({ target = ".state/dir", kind = "directory", private = true }),
}))
applied_plans[none.generation] = none
provisioner.apply(none)
local stripped = paths.read(paths.home .. "/.statenv")
assert(not stripped:find("# test: frag-b", 1, true), "last fragment block survived")
assert(stripped:find("# user keeps this", 1, true) and vim.uv.fs_stat(paths.home .. "/.statenv"), "shared file deleted")

-- Arbitrary whole-body modify programs report unsupported reversal instead
-- of claiming removal when their recipe disappears.
local whole = source.plan(application_for({
	provision.chezmoi({ target = ".state/file-a", kind = "file", asset = "payload" }),
	provision.chezmoi({ target = ".state/link-a", kind = "symlink", to = "../opt/tool" }),
	provision.chezmoi({ target = ".state/dir", kind = "directory", private = true }),
	provision.chezmoi({ target = ".wholeenv", kind = "modify", executable = true, content = "#!/bin/sh\ncat\n" }),
}))
applied_plans[whole.generation] = whole
provisioner.apply(whole)
assert(vim.uv.fs_stat(paths.home .. "/.wholeenv"))
local after_whole = plan_for({})
assert(#after_whole.unsupported_reversals == 1 and after_whole.unsupported_reversals[1].target == ".wholeenv")
provisioner.apply(after_whole)
assert(vim.uv.fs_stat(paths.home .. "/.wholeenv"), "whole-body modify target was deleted on retirement")

-- Writing through a symlinked ancestor is refused before backend mutation.
assert(vim.uv.fs_symlink(paths.join(paths.home, "state-real"), paths.home .. "/.via-link"))
assert(vim.uv.fs_mkdir(paths.join(paths.home, "state-real"), 448))
assert_fails("refusing to write through symlinked ancestor", function()
	provisioner.apply(plan_with({
		provision.chezmoi({ target = ".via-link/file", kind = "file", content = "x\n" }),
	}))
end)
assert(not paths.exists(paths.home .. "/state-real/file"), "write escaped through the symlinked ancestor")

-- Recipe evolution from a byte-owned file to a modify program converges a
-- runtime-drifted owned target without conflict: the modify precondition
-- never byte-compares, which is the ownership model the nvim package uses
-- for the runtime-extended lazy-lock.json.
local lockfile_baseline = '{\n  "plugin": { "branch": "main", "commit": "aaaa" }\n}\n'
local lockfile_runtime =
	'{\n  "plugin": { "branch": "main", "commit": "aaaa" },\n  "host-theme": { "branch": "v3", "commit": "bbbb" }\n}\n'
local as_file = {
	provision.chezmoi({ target = ".state/lazy-lock.json", kind = "file", content = lockfile_baseline }),
}
provisioner.apply(plan_with(as_file, {}))
paths.write(paths.home .. "/.state/lazy-lock.json", lockfile_runtime)
assert_fails("target changed since the last successful apply", function()
	provisioner.apply(plan_with(as_file, {}))
end)
local as_modify = {
	provision.chezmoi({
		target = ".state/lazy-lock.json",
		kind = "modify",
		executable = true,
		content = "#!/bin/sh\ncat <<'__LOCK__'\n" .. lockfile_runtime .. "__LOCK__\n",
	}),
}
provisioner.apply(plan_with(as_modify, {}))
assert(
	paths.read(paths.home .. "/.state/lazy-lock.json") == lockfile_runtime,
	"modify recipe clobbered runtime-extended state"
)
assert(
	state.applied_record().targets[".state/lazy-lock.json"].operation == "modify",
	"journal kept the retired file operation"
)
provisioner.apply(plan_with(as_modify, {}))
assert(
	paths.read(paths.home .. "/.state/lazy-lock.json") == lockfile_runtime,
	"repeated modify apply destabilized the target"
)
print("file-to-modify recipe swap converges runtime drift")

commands.execute = real_execute
print(
	"state journal tests passed (preconditions, adoption, pending/failed evidence, exclusive retirement, fragment recomposition, unsupported reversal)"
)
