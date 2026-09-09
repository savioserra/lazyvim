-- Parent-disposition correction coverage (R1-R8): adversarial, red/green
-- tests through the actual public recipe helpers, collector, assembler,
-- compositor, state and provisioner paths. The backend child is the same fake
-- desired-state applier used by journal.test.lua (plain filesystem writes plus
-- execution of the real generated modify programs); native backend semantics
-- stay in backend-render.test.lua.
local repository = vim.fn.getcwd()
local root = vim.fs.joinpath(repository, "workstation")
package.path = table.concat({
	vim.fs.joinpath(root, "?.lua"),
	vim.fs.joinpath(root, "?", "init.lua"),
	vim.fs.joinpath(root, "lua", "?.lua"),
	vim.fs.joinpath(root, "lua", "?", "init.lua"),
	package.path,
}, ";")

local changesets = require("workstation.changesets")
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

local function application_for(contributes)
	return {
		context = {},
		graph = { ordered = { { id = "test-package", contributes = contributes } } },
		packages_roots = { ["test-package"] = package_root },
	}
end

-- Fake backend: applies the plan's desired state directly and executes the
-- real generated modify programs through sh.
local applied_plans, fail_next, fail_after = {}, false, nil
local real_execute = commands.execute
commands.execute = function(executable, argv)
	assert(executable:sub(-#"chezmoi") == "chezmoi", "unexpected child executed: " .. executable)
	assert(argv[1] == "--source" and argv[5] == "apply", "unexpected backend invocation")
	if fail_next then
		fail_next = false
		error("fake backend apply failure")
	end
	local plan = assert(applied_plans[argv[2]:match("([^/]+)$")], "backend received an unpublished generation")
	for _, entry in ipairs(plan.entries) do
		local target = state.join_home(entry.target)
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
			local script = paths.join(argv[2], entry.source_name)
			local result = vim.system({ "sh", script }, { stdin = current, text = true }):wait()
			assert(result.code == 0, "generated modify program failed: " .. (result.stderr or ""))
			paths.write(target, result.stdout)
			vim.uv.fs_chmod(target, entry.mode or 493)
		else
			paths.write(target, entry.bytes)
			vim.uv.fs_chmod(target, entry.mode or 420)
		end
		if fail_after == entry.target then
			fail_after = nil
			error("fake backend failed after writing " .. entry.target)
		end
	end
	local removed = vim.split(vim.trim(paths.read(paths.join(argv[2], ".chezmoiremove"))), "\n")
	for _, removal in ipairs(removed) do
		vim.fn.delete(state.join_home(removal), "rf")
	end
end

local function plan_for(contributes)
	local plan = source.plan(application_for(contributes))
	applied_plans[plan.generation] = plan
	return plan
end

local function apply_for(contributes)
	return provisioner.apply(plan_for(contributes))
end

local function base(extra, without_shell)
	local contributes = {
		provision.chezmoi({ target = ".state/file-a", kind = "file", asset = "payload" }),
		provision.chezmoi({ target = ".state/link-a", kind = "symlink", to = "../opt/tool" }),
	}
	if not without_shell then
		vim.list_extend(contributes, {
			provision.shell({
				target = ".statenv",
				fragment = { id = "frag-a", order = 10, marker = "# test: frag-a", body = "echo a" },
			}),
		})
	end
	if extra then
		vim.list_extend(contributes, extra)
	end
	return contributes
end

-- R1: fragments are only provision.shell input; a fragments-only native
-- modifier can never reach collection, generation or a target.
do
	local shell = require("workstation.provision.shell")
	assert_fails("they belong to provision.shell only", function()
		provision.chezmoi({ target = ".profile", kind = "modify", fragments = { { id = "a" } } })
	end)
	-- A hand-built envelope smuggling fragments past the constructor is
	-- rejected at collection with an unknown-field failure.
	local application = application_for({
		{ provider = "chezmoi", spec = { target = ".profile", kind = "modify", fragments = { { id = "x" } } } },
	})
	assert_fails("unknown field fragments", function()
		source.plan(application)
	end)
	-- Generated regular source files always carry bytes and manifests digests.
	local plan = plan_for(base())
	for _, entry in ipairs(plan.entries) do
		assert(
			entry.type == "directory" or entry.bytes ~= nil,
			"generated source entry without bytes: " .. entry.source_name
		)
	end
	for _, manifest_entry in ipairs(plan.manifest) do
		assert(manifest_entry.type ~= "file" or manifest_entry.sha256, "manifest file without digest")
	end
	-- A nil-body hand-built spec cannot pass validation at collection.
	assert_fails("requires content or a package-relative asset", function()
		source.plan(application_for({
			{
				provider = "chezmoi",
				spec = { target = ".state/empty", kind = "file", components = { ".state", "empty" } },
			},
		}))
	end)
	-- The shell compositor remains the structured-fragment path.
	local program = shell.compose(".x", { { id = "a", marker = "# a", body = "echo a", order = 1 } }, {})
	assert(program:find("# a", 1, true))
end

-- R3: native-name and removal literal safety at the public constructor and at
-- collection; mutated components cannot redirect the generated path.
do
	assert_fails("reserved prefix dot_", function()
		provision.chezmoi({ target = "dot_profile", kind = "file", content = "x\n" })
	end)
	assert_fails("reserved prefix modify_", function()
		provision.chezmoi({ target = "modify_tool", kind = "file", content = "x\n" })
	end)
	assert_fails("reserved prefix private_", function()
		provision.chezmoi({ target = "private_notes", kind = "file", content = "x\n" })
	end)
	assert_fails("reserved prefix symlink_", function()
		provision.chezmoi({ target = "symlink_bin", kind = "file", content = "x\n" })
	end)
	assert_fails("reserved prefix executable_", function()
		provision.chezmoi({ target = ".config/executable_run", kind = "file", content = "x\n" })
	end)
	assert_fails("ending in .tmpl is only representable", function()
		provision.chezmoi({ target = ".config/render.tmpl", kind = "file", content = "x\n" })
	end)
	assert(
		provision.chezmoi({
			target = ".config/render.tmpl",
			kind = "file",
			content = "{{ .chezmoi.os }}\n",
			template = true,
		}),
		"intended template targets remain representable"
	)
	assert_fails("control characters or newlines", function()
		provision.chezmoi({ target = ".config/bad\nname", kind = "file", content = "x\n" })
	end)
	-- A mutated component list is rejected at collection.
	assert_fails("does not re-derive", function()
		local recipe = provision.chezmoi({ target = ".state/file-a", kind = "file", asset = "payload" })
		recipe.spec.components[2] = "hijacked"
		source.plan(application_for({ recipe }))
	end)
	-- Unknown spec fields are rejected at collection.
	assert_fails("unknown field mode", function()
		source.plan(application_for({
			{
				provider = "chezmoi",
				spec = {
					target = ".state/x",
					kind = "file",
					components = { ".state", "x" },
					mode = "0600",
					content = "x",
				},
			},
		}))
	end)
	-- Removal literals: glob metacharacters, control bytes and traversals
	-- cannot expand one owned target into several removals.
	assert_fails("glob metacharacters", function()
		plan_for(base({ provision.chezmoi({ target = ".cache/*", kind = "remove" }) }))
	end)
	assert_fails("glob metacharacters", function()
		plan_for(base({ provision.chezmoi({ target = ".cache/old?[1]", kind = "remove" }) }))
	end)
	assert_fails("control characters or newlines", function()
		plan_for(base({ provision.chezmoi({ target = ".cache/old\nx", kind = "remove" }) }))
	end)
end

-- R2/R7: destructive containment, exact ownership and remove semantics
-- through the real apply pipeline.
do
	-- Removals may never encompass engine-private state.
	assert_fails("encompasses engine-private state", function()
		plan_for(base({ provision.chezmoi({ target = ".local", kind = "remove" }) }))
	end)
	assert_fails("overlaps owned target", function()
		plan_for(base({ provision.chezmoi({ target = ".state", kind = "remove" }) }))
	end)
	-- Declared remove of an absent, never-owned target is a no-op.
	local noop = plan_for(base({ provision.chezmoi({ target = ".never/owned", kind = "remove" }) }))
	assert(#noop.removals == 0, "absent unrecorded removal was activated: " .. #noop.removals)
	assert(not noop.remove_file:find(".never/owned", 1, true), "no-op removal became a tombstone")
	-- Declared remove of an existing never-journaled target conflicts.
	paths.write(paths.home .. "/.user/file", "user data\n")
	assert_fails("was never recorded as owned", function()
		provisioner.apply(plan_for(base({ provision.chezmoi({ target = ".user/file", kind = "remove" }) })))
	end)
	assert(paths.read(paths.home .. "/.user/file") == "user data\n", "unrecorded removal mutated user data")
	-- Recorded ownership removes idempotently after a matching fingerprint.
	local first = plan_for(base())
	provisioner.apply(first)
	local extra = plan_for(base({
		provision.chezmoi({ target = ".state/temp", kind = "file", content = "temp\n" }),
	}))
	provisioner.apply(extra)
	local retiring = plan_for(base())
	assert(#retiring.removals == 1 and retiring.removals[1].target == ".state/temp", "retirement not planned")
	provisioner.apply(retiring)
	assert(not paths.exists(paths.home .. "/.state/temp"), "owned leaf was not removed")
	provisioner.apply(plan_for(base()))
	-- Exact management: existing unknown content fails closed.
	local exact = {
		provision.chezmoi({ target = ".exact-tree", kind = "directory", exact = true }),
		provision.chezmoi({ target = ".exact-tree/managed", kind = "file", content = "m\n" }),
	}
	local exact_plan = plan_for(vim.list_extend(base(nil, true), exact))
	-- First adoption over existing unknown contents fails closed instead of
	-- letting the backend prune them.
	vim.fn.mkdir(paths.home .. "/.exact-tree", "p")
	paths.write(paths.home .. "/.exact-tree/user-file", "user\n")
	assert_fails("exact directory contains unproven content", function()
		provisioner.apply(exact_plan)
	end)
	assert(paths.read(paths.home .. "/.exact-tree/user-file") == "user\n", "exact adoption pruned user content")
	vim.fn.delete(paths.home .. "/.exact-tree", "rf")
	provisioner.apply(plan_for(vim.list_extend(base(nil, true), exact)))
	assert(paths.read(paths.home .. "/.exact-tree/managed") == "m\n")
	-- A foreign child appearing after adoption conflicts on the next apply.
	paths.write(paths.home .. "/.exact-tree/foreign", "user\n")
	assert_fails("exact directory contains unproven content", function()
		provisioner.apply(plan_for(vim.list_extend(base(nil, true), exact)))
	end)
	assert(paths.read(paths.home .. "/.exact-tree/foreign") == "user\n", "conflict pruned foreign content")
	vim.fn.delete(paths.home .. "/.exact-tree/foreign", "rf")
	-- An empty pre-existing exact directory is adoptable.
	provisioner.apply(plan_for(vim.list_extend(base(nil, true), exact)))
end

-- R4: full fingerprints, stale plans and partial attempts.
do
	local applied = plan_for(base())
	provisioner.apply(applied)
	-- A mode-only change is an intervening edit.
	assert(vim.uv.fs_chmod(paths.home .. "/.state/file-a", 448))
	assert_fails("target changed since the last successful apply", function()
		provisioner.apply(applied)
	end)
	assert(vim.uv.fs_chmod(paths.home .. "/.state/file-a", 420))
	-- Stale plan: a newer successful generation must block an older plan.
	local stale = plan_for(base())
	local newer = plan_for(base({
		provision.chezmoi({ target = ".state/file-b", kind = "file", content = "b-v1\n" }),
	}))
	provisioner.apply(newer)
	assert_fails("stale plan", function()
		provisioner.apply(stale)
	end)
	-- Re-applying the current desired generation is an idempotent no-op.
	provisioner.apply(plan_for(base({
		provision.chezmoi({ target = ".state/file-b", kind = "file", content = "b-v1\n" }),
	})))
	-- First adoption compares full state: identical content with a different
	-- mode conflicts instead of silently owning the file.
	paths.write(paths.home .. "/.state/adopt", "managed\n")
	assert(vim.uv.fs_chmod(paths.home .. "/.state/adopt", 448))
	local adopt = plan_for(base({
		provision.chezmoi({ target = ".state/file-b", kind = "file", content = "b-v1\n" }),
		provision.chezmoi({ target = ".state/adopt", kind = "file", content = "managed\n" }),
	}))
	assert_fails("differing in type, mode, content or link", function()
		provisioner.apply(adopt)
	end)
	assert(vim.uv.fs_chmod(paths.home .. "/.state/adopt", 420))
	provisioner.apply(adopt)
	assert(state.applied_record().targets[".state/adopt"], "identical adoption was not recorded")
	-- An unresolved partial attempt for another generation blocks a plan whose
	-- proof is missing instead of being silently forgotten.
	fail_after = ".state/loose"
	assert_fails("fake backend failed after writing", function()
		provisioner.apply(plan_for(base({
			provision.chezmoi({ target = ".state/file-c", kind = "file", content = "c\n" }),
			provision.chezmoi({ target = ".state/loose", kind = "file", content = "loose\n" }),
		})))
	end)
	assert(paths.read(paths.home .. "/.state/loose") == "loose\n", "partial write did not happen")
	assert(#state.pending_records() == 1, "pending attempt was not retained")
	-- Drop .state/loose from the declarations: the unproven partial write must
	-- block until it is recovered explicitly.
	assert_fails("unresolved partial attempt", function()
		provisioner.apply(plan_for(base({
			provision.chezmoi({ target = ".state/file-c", kind = "file", content = "c\n" }),
		})))
	end)
	-- Explicit fixture-only recovery: remove the unproven target, then apply.
	vim.fn.delete(paths.home .. "/.state/loose")
	provisioner.apply(plan_for(base({
		provision.chezmoi({ target = ".state/file-c", kind = "file", content = "c\n" }),
	})))
	assert(#state.pending_records() == 0)
end

-- R5: active, replaced and retiring shell-block integrity.
do
	local function run_program(program, input)
		local scratch = vim.fn.tempname()
		vim.fn.mkdir(scratch, "p")
		local script = paths.join(scratch, "program")
		paths.write(script, program)
		vim.uv.fs_chmod(script, 448)
		local result = vim.system({ "sh", script }, { stdin = input, text = true }):wait()
		return result.code, result.stdout or ""
	end
	local shell = require("workstation.provision.shell")
	local recorded = { frag = { id = "frag", marker = "# m", body = "old body" } }
	-- Retained fragment with an edited body conflicts in the generated program.
	local edited_input = "# user\n\n# m\nedited body\n"
	local program = shell.compose(".x", { { id = "frag", marker = "# m", body = "old body", order = 1 } }, recorded)
	local code = run_program(program, edited_input)
	assert(code ~= 0, "edited active block passed the generated modifier")
	-- ... and in the pre-backend validation.
	local scratch_file = vim.fn.tempname()
	paths.write(scratch_file, edited_input)
	local ok, conflict =
		shell.validate_target(scratch_file, { { id = "frag", marker = "# m", body = "old body" } }, recorded)
	assert(not ok and conflict:find("edited", 1, true), "pre-backend validation missed the edit")
	-- A duplicated owned block conflicts.
	local duplicated = "# m\nold body\n\n# m\nold body\n"
	paths.write(scratch_file, duplicated)
	local code2 = run_program(program, duplicated)
	assert(code2 ~= 0, "duplicated active block passed the generated modifier")
	local ok2, conflict2 =
		shell.validate_target(scratch_file, { { id = "frag", marker = "# m", body = "old body" } }, recorded)
	assert(not ok2 and conflict2:find("duplicated", 1, true))
	-- A same-id body change replaces the exact old block with the new one.
	local replaced = shell.compose(".x", { { id = "frag", marker = "# m", body = "new body", order = 1 } }, recorded)
	local replaced_input = "# user\n\n# m\nold body\n"
	local code3, output = run_program(replaced, replaced_input)
	assert(code3 == 0, "same-id replacement failed")
	assert(output:find("# user", 1, true) and output:find("new body", 1, true), "replacement lost content")
	assert(not output:find("old body", 1, true), "old block survived replacement")
	-- A same-id marker change moves the block.
	local moved = shell.compose(".x", { { id = "frag", marker = "# m2", body = "new body", order = 1 } }, recorded)
	local code4, output4 = run_program(moved, replaced_input)
	assert(code4 == 0 and output4:find("# m2", 1, true) and not output4:find("# m\n", 1, true))
	-- Duplicate marker ownership across ids is rejected at collection.
	assert_fails("duplicate shell marker", function()
		plan_for({
			provision.shell({
				target = ".dual",
				fragment = { id = "one", order = 1, marker = "# same", body = "a" },
			}),
			provision.shell({
				target = ".dual",
				fragment = { id = "two", order = 2, marker = "# same", body = "b" },
			}),
		})
	end)
	-- Unsafe fragment ids cannot leak into generated comments.
	assert_fails("must not contain control characters or newlines", function()
		provision.shell({
			target = ".x",
			fragment = { id = "bad\nid", order = 1, marker = "# m", body = "b" },
		})
	end)
	-- End-to-end through the engine: an edited active block stops before the
	-- backend mutates anything else.
	provisioner.apply(plan_for(base()))
	paths.write(paths.home .. "/.statenv", paths.read(paths.home .. "/.statenv"):gsub("echo a", "echo tampered"))
	-- Snapshot the tampered state: the engine must stop on the conflict
	-- without touching any other owned target.
	local before = {}
	for _, entry in ipairs(plan_for(base()).entries) do
		local file = io.open(state.join_home(entry.target), "rb")
		if file then
			before[entry.target] = file:read("*a")
			file:close()
		end
	end
	assert_fails("edited, duplicated or ambiguous", function()
		provisioner.apply(plan_for(base()))
	end)
	for target, contents in pairs(before) do
		local file = io.open(state.join_home(target), "rb")
		if file then
			assert(file:read("*a") == contents, "conflict mutated owned target " .. target)
			file:close()
		end
	end
end

-- R6: engine-state confinement, exclusive temporaries and bounded diagnostics.
do
	-- A redirected engine-state root via symlink fails closed before writes.
	local sentinel = vim.fn.tempname()
	paths.write(sentinel, "sentinel bytes\n")
	local home = paths.home
	assert(vim.uv.fs_symlink(sentinel, home .. "/.local/state/workstation") or vim.uv.fs_lstat(home .. "/.local/state"))
	-- state.root must refuse the symlinked path (or an existing non-directory).
	local ok, failure = pcall(function()
		require("workstation.state").root()
	end)
	if not ok then
		assert(
			tostring(failure):find("not a directory") or tostring(failure):find("engine state"),
			"unexpected confinement failure: " .. tostring(failure)
		)
	end
	assert(paths.read(sentinel) == "sentinel bytes\n", "sentinel bytes changed through the redirect")
	vim.fn.delete(home .. "/.local/state/workstation", "")
	-- Malformed lock content stays fail-closed with a bounded diagnostic.
	local state_root = require("workstation.state").root()
	paths.write(paths.join(state_root, "apply.lock"), "not json at all")
	local ok2, failure2 = pcall(require("workstation.state").acquire_lock, "probe")
	assert(not ok2, "malformed lock was taken")
	assert(
		tostring(failure2):find("locked by another operation", 1, true)
			and tostring(failure2):find("unreadable or malformed", 1, true),
		"unbounded or missing lock diagnostic: " .. tostring(failure2)
	)
	assert(not tostring(failure2):find("not json at all", 1, true), "lock body leaked into the diagnostic")
	vim.fn.delete(paths.join(state_root, "apply.lock"))
	-- Journal-derived identifiers are validated before path use.
	assert(not state.valid_generation_id("../../etc"), "traversal accepted as a generation id")
	assert(not state.valid_generation_id("ABC"), "non-hex accepted as a generation id")
	assert_fails("invalid generation identifier", function()
		state.generation_directory("../escape")
	end)
	-- A pre-created staging path is never deleted or written through: publish
	-- allocates a different exclusive staging directory.
	local generations = state.generations_root()
	local planted = paths.join(generations, (".staging-%d-1-1"):format(vim.uv.os_getpid()))
	vim.fn.mkdir(planted, "p")
	paths.write(paths.join(planted, "unproven"), "do not delete\n")
	local plan = plan_for(base())
	provisioner.publish(plan)
	assert(paths.read(paths.join(planted, "unproven")) == "do not delete\n", "unproven staging path was deleted")
	vim.fn.delete(planted, "rf")
end

-- R8: complete add/change/delete patch previews bound to a verified baseline.
do
	-- Model a fresh host: no journal, no generations, so the first plan is an
	-- initial plan whose every entry must preview as an addition.
	vim.fn.delete(paths.join(state.journal_root(), "applied.json"))
	vim.fn.delete(state.generations_root(), "rf")
	vim.fn.delete(paths.home .. "/.state", "rf")
	vim.fn.delete(paths.home .. "/.statenv")
	local initial = plan_for(base())
	local patches = changesets.plan_patches(initial)
	local adds = vim.tbl_filter(function(entry)
		return entry.kind == "add"
	end, patches)
	assert(
		#adds == #initial.entries,
		("initial plan must preview every entry as an addition: %d/%d"):format(#adds, #initial.entries)
	)
	local typed = vim.tbl_filter(function(entry)
		return entry.link == "../opt/tool"
	end, patches)
	assert(#typed == 1, "symlink entry lost typed link metadata")
	-- After a successful apply, an unchanged plan previews nothing.
	provisioner.apply(initial)
	local noop_patches = changesets.plan_patches(plan_for(base()))
	assert(#noop_patches == 0, "unchanged plan produced patches: " .. #noop_patches)
	-- A content change previews exactly that change with a real diff.
	local changed = plan_for(base({
		provision.chezmoi({ target = ".state/file-z", kind = "file", content = "z-v1\n" }),
	}))
	provisioner.apply(changed)
	local upgrade = plan_for(base({
		provision.chezmoi({ target = ".state/file-z", kind = "file", content = "z-v2\n" }),
	}))
	local change_patches = vim.tbl_filter(function(entry)
		return entry.kind == "change"
	end, changesets.plan_patches(upgrade))
	assert(#change_patches == 1 and change_patches[1].source == "dot_state/file-z", "change preview missing")
	assert(
		change_patches[1].diff:find("%-z%-v1", 1, false) and change_patches[1].diff:find("%+z%-v2", 1, false),
		"change patch lacks a real diff"
	)
	-- Retiring the entry previews a deletion against the verified baseline.
	provisioner.apply(upgrade)
	local retired = plan_for(base())
	local delete_patches = vim.tbl_filter(function(entry)
		return entry.kind == "delete"
	end, changesets.plan_patches(retired))
	assert(#delete_patches == 1 and delete_patches[1].source == "dot_state/file-z", "delete preview missing")
	assert(delete_patches[1].diff:find("%-z%-v2", 1, false), "delete patch lacks the removed bytes")
	-- A tampered baseline directory refuses to fabricate patches.
	local applied = state.applied_record()
	local baseline_dir = state.generation_directory(applied.generation)
	paths.write(paths.join(baseline_dir, "dot_state/file-a"), "tampered baseline\n")
	assert_fails("no longer matches its journaled manifest", function()
		changesets.plan_patches(plan_for(base()))
	end)
end

commands.execute = real_execute
print(
	"correction tests passed (R1 fragments, R2/R7 containment and remove semantics, R3 name/removal safety, R4 fingerprints/stale plans/partial attempts, R5 shell integrity, R6 state confinement, R8 patch surface)"
)
