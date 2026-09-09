-- Provider contract, generation, conflict, journal, lock and reconciliation
-- tests. These run without the real backend: they exercise the actual public
-- recipe constructors, collector, compositor, assembler and state paths.
local repository = vim.fn.getcwd()
local root = vim.fs.joinpath(repository, "workstation")
package.path = table.concat({
	vim.fs.joinpath(root, "?.lua"),
	vim.fs.joinpath(root, "?", "init.lua"),
	vim.fs.joinpath(root, "lua", "?.lua"),
	vim.fs.joinpath(root, "lua", "?", "init.lua"),
	package.path,
}, ";")

local chezmoi = require("workstation.provision.chezmoi")
local paths = require("workstation.paths")
local policy = require("workstation.provision.policy")
local profile_module = require("packages.nvim.profile")
local provision = require("workstation.provision.recipes")
local shell = require("workstation.provision.shell")
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

-- Recipe construction is pure: options are copied and later mutation cannot
-- alter the declared recipe.
do
	local options = { target = ".config/example", kind = "file", content = "one\n" }
	local recipe = provision.chezmoi(options)
	assert(recipe.provider == "chezmoi" and recipe.spec.content == "one\n")
	options.content = "two\n"
	assert(recipe.spec.content == "one\n", "recipe constructor did not copy options")
	assert(recipe.spec.components[1] == ".config" and recipe.spec.components[2] == "example")
	assert_fails("unknown option", function()
		provision.chezmoi({ target = ".x", kind = "file", content = "x", mode = "0600" })
	end)
	assert_fails("unsupported kind", function()
		provision.chezmoi({ target = ".x", kind = "socket", content = "x" })
	end)
	assert_fails("requires a target", function()
		provision.chezmoi({ kind = "file", content = "x" })
	end)
	assert_fails("exactly one inline body or package-relative asset", function()
		provision.chezmoi({ target = ".x", kind = "file", content = "x", asset = "files/x" })
	end)
	assert_fails("must be relative to the destination home", function()
		provision.chezmoi({ target = "/etc/passwd", kind = "file", content = "x" })
	end)
	assert_fails("must not traverse", function()
		provision.chezmoi({ target = "../escape", kind = "file", content = "x" })
	end)
	assert_fails("exactly a link destination", function()
		provision.chezmoi({ target = ".local/bin/x", kind = "symlink", to = "../opt/x", content = "x" })
	end)
	-- R1: structured fragments belong to provision.shell ONLY; a native
	-- modify recipe with fragments is rejected by the public constructor
	-- before any collection, source generation or target mutation.
	assert_fails("they belong to provision.shell only", function()
		provision.chezmoi({ target = ".profile", kind = "modify", content = "x", fragments = { { id = "a" } } })
	end)
	assert_fails("they belong to provision.shell only", function()
		provision.chezmoi({ target = ".profile", kind = "modify", fragments = { { id = "a" } } })
	end)
	assert_fails("they belong to provision.shell only", function()
		provision.chezmoi({ target = ".profile", kind = "file", content = "x", fragments = { { id = "a" } } })
	end)
	assert_fails("accepts no content", function()
		provision.chezmoi({ target = ".old", kind = "remove", content = "x" })
	end)
	assert_fails("escapes the destination home", function()
		provision.chezmoi({ target = ".config/a/b", kind = "symlink", to = "../../../../etc" })
	end)
end

-- Native name encoding is one-way from logical target plus attributes,
-- including ancestor directory attributes.
do
	local function name_for(options, ancestors)
		return chezmoi.source_name(chezmoi.recipe(options).spec, ancestors)
	end
	assert(name_for({ target = ".profile", kind = "file", content = "x" }) == "dot_profile")
	assert(
		name_for({ target = ".profile", kind = "modify", executable = true, content = "x" })
			== "modify_executable_dot_profile"
	)
	assert(
		name_for({ target = ".config/nvim/init.lua", kind = "file", content = "x" }) == "dot_config/nvim/init.lua",
		"nested plain file"
	)
	assert(
		name_for({ target = ".config/nvim/.gitignore", kind = "file", content = "x" })
			== "dot_config/nvim/dot_gitignore"
	)
	assert(name_for({ target = ".local/bin/nvim", kind = "symlink", to = "/x" }) == "dot_local/bin/symlink_nvim")
	assert(name_for({ target = ".x", kind = "file", content = "x", template = true }) == "dot_x.tmpl")
	assert(name_for({ target = ".cache/tool", kind = "directory", private = true }) == "dot_cache/private_tool")
	assert(name_for({ target = ".cache/tool", kind = "directory", exact = true }) == "dot_cache/exact_tool")
	assert(
		name_for({
			target = ".pi/agent/skills/x/SKILL.md",
			kind = "file",
			content = "x",
		}, { [".pi/agent"] = { private = true } }) == "dot_pi/private_agent/skills/x/SKILL.md",
		"private ancestor component"
	)
	assert(name_for({ target = ".x", kind = "file", content = "x", private = true }) == "private_dot_x", "private file")
	-- Native file permission metadata, proven against the trusted backend:
	-- private 0600, executable 0755, private+executable 0700 (owner-only).
	assert(
		chezmoi.entry_mode(chezmoi.recipe({ target = ".x", kind = "file", content = "x", private = true }).spec) == 384
	)
	assert(
		chezmoi.entry_mode(
			chezmoi.recipe({ target = ".x", kind = "file", content = "x", private = true, executable = true }).spec
		) == 448
	)
	assert(
		chezmoi.entry_mode(chezmoi.recipe({ target = ".x", kind = "file", content = "x", executable = true }).spec)
			== 493
	)
	assert(chezmoi.entry_mode(chezmoi.recipe({ target = ".x", kind = "file", content = "x" }).spec) == 420)
	assert_fails("no chezmoi source name", function()
		chezmoi.source_name(chezmoi.recipe({ target = ".old", kind = "remove" }).spec)
	end)
end

-- The engine tombstone policy keeps exactly the seventeen baseline entries.
do
	assert(#policy.legacy_removals == 17, "expected seventeen legacy tombstones")
	local body = policy.remove_file({ ".local/share/lazyvim", ".custom/retired" })
	local lines = vim.split(vim.trim(body), "\n")
	assert(#lines == 18, "deduplication failed: " .. #lines)
	assert(lines[1] == ".local/share/lazyvim" and lines[18] == ".custom/retired")
	assert(policy.remove_file({ ".custom/retired", ".custom/retired" }) == body, "deduplication changed the body")
end

-- Shell fragment composition: explicit order with graph-order tie-breaking,
-- duplicate fragment rejection, and exact-block retirement programs.
do
	local function fragment(id, order, marker, body)
		return shell.recipe({ target = ".profile", fragment = { id = id, order = order, marker = marker, body = body } })
	end
	assert_fails("requires a marker", function()
		shell.recipe({ target = ".profile", fragment = { id = "x", body = "y", order = 1 } })
	end)
	assert_fails("must not contain control characters or newlines", function()
		shell.recipe({
			target = ".profile",
			fragment = { id = "x", marker = "# m", body = "two\nlines", order = 1 },
		})
	end)
	assert_fails("positive integer order", function()
		shell.recipe({ target = ".profile", fragment = { id = "x", marker = "# m", body = "y", order = 1.5 } })
	end)
	local program, ids = shell.compose(".profile", {
		{ id = "second", marker = "# second", body = "echo second", order = 20 },
		{ id = "first", marker = "# first", body = "echo first", order = 10 },
	}, {})
	assert(vim.deep_equal(ids, { "first", "second" }), "fragments did not order by explicit order")
	assert(program:find("# second", 1, true) and program:find("# first", 1, true))
	-- determinism
	local again = shell.compose(".profile", {
		{ id = "second", marker = "# second", body = "echo second", order = 20 },
		{ id = "first", marker = "# first", body = "echo first", order = 10 },
	}, {})
	assert(again == program, "composition is not deterministic")
	-- the composed program is executable POSIX sh and idempotent on content
	local scratch = vim.fn.tempname()
	vim.fn.mkdir(scratch, "p")
	local script = scratch .. "/program"
	paths.write(script, program)
	assert(vim.uv.fs_chmod(script, 448))
	local initial = "# user\nexport A=1\n"
	local function run_pipe(input)
		local input_file = scratch .. "/in"
		paths.write(input_file, input)
		local result = vim.system({ "sh", "-c", script .. " < " .. vim.fn.shellescape(input_file) }, { text = true })
			:wait()
		assert(result.code == 0, result.stderr)
		return result.stdout
	end
	local once = run_pipe(initial)
	assert(once:find("# user", 1, true) and once:find("export A=1", 1, true), "user text lost")
	assert(once:find("# first", 1, true) and once:find("echo first", 1, true))
	assert(once:find("# second", 1, true) and once:find("echo second", 1, true))
	assert(once:find("\n# first\necho first\n\n# second\necho second\n$") ~= nil, "unexpected block layout")
	local twice = run_pipe(once)
	assert(twice == once, "composition is not idempotent")
	-- retirement removes exactly the known block and preserves the rest
	local retired = shell.compose(".profile", {
		{ id = "first", marker = "# first", body = "echo first", order = 10 },
	}, { { id = "second", marker = "# second", body = "echo second" } })
	paths.write(script, retired)
	local removed = run_pipe(once)
	assert(not removed:find("# second", 1, true), "retired block survived")
	assert(removed:find("# first", 1, true) and removed:find("# user", 1, true), "surviving content lost")
	-- an edited owned block conflicts instead of guessing
	local edited = once:gsub("echo second", "echo tampered")
	paths.write(script, retired)
	local tampered_file = scratch .. "/tampered"
	paths.write(tampered_file, edited)
	local result = vim.system({ "sh", "-c", script .. " < " .. vim.fn.shellescape(tampered_file) }, { text = true })
		:wait()
	assert(result.code ~= 0, "edited owned block was removed without conflict")
	assert(edited:find("echo tampered", 1, true), "edited target content changed on conflict")
	-- a duplicated owned block is ambiguous and conflicts
	local duplicated = once .. once
	paths.write(tampered_file, duplicated)
	local result = vim.system({ "sh", "-c", script .. " < " .. vim.fn.shellescape(tampered_file) }, { text = true })
		:wait()
	assert(result.code ~= 0, "duplicate owned block was removed without conflict")
	vim.fn.delete(scratch, "rf")
end

-- Profile recipe validation and composition order.
do
	assert_fails("positive integer order", function()
		profile_module.recipe({ order = 0, entry = { id = "x" } })
	end)
	assert_fails("unknown option", function()
		profile_module.recipe({ order = 1, entry = { id = "x" }, extra = true })
	end)
	assert_fails("must be a non-empty string", function()
		profile_module.recipe({
			order = 1,
			entry = { id = "x", language_cases = { { language = "lua" } } },
		})
	end)
	local composer = require("packages.nvim.compose")
	local recipe, profile, owners = composer.compose({
		{ owner = "nvim", spec = profile_module.recipe({ order = 30, entry = { id = "standard" } }).spec },
		{ owner = "typescript", spec = profile_module.recipe({ order = 20, entry = { id = "typescript" } }).spec },
		{ owner = "nvim", spec = profile_module.recipe({ order = 10, entry = { id = "go" } }).spec },
	})
	assert(profile[1].id == "go" and profile[2].id == "typescript" and profile[3].id == "standard")
	assert(vim.deep_equal(owners, { "nvim", "typescript", "nvim" }))
	assert(recipe.spec.target == composer.target and recipe.provider == "chezmoi")
	local loaded = assert(loadfile((function()
		local path = vim.fn.tempname()
		paths.write(path, recipe.spec.content)
		return path
	end)()))()
	assert(loaded[3].id == "standard")
	assert_fails("duplicate Neovim profile contribution", function()
		composer.compose({
			{ owner = "a", spec = profile_module.recipe({ order = 1, entry = { id = "x" } }).spec },
			{ owner = "b", spec = profile_module.recipe({ order = 2, entry = { id = "x" } }).spec },
		})
	end)
	assert_fails("at least one intent", function()
		composer.compose({})
	end)
end

-- Build a plan for a synthetic package graph against the isolated HOME. The
-- synthetic package root holds real asset files so confinement is exercised
-- against ordinary on-disk state, never the repository itself.
local package_root = vim.fn.tempname()
vim.fn.mkdir(package_root, "p")
local function application_for(contributes_by_id)
	local ordered = {}
	for id, contributes in pairs(contributes_by_id) do
		table.insert(ordered, { id = id, contributes = contributes })
	end
	table.sort(ordered, function(left, right)
		return left.id < right.id
	end)
	return {
		context = { nvim_profile = nil },
		graph = { ordered = ordered },
		packages_roots = setmetatable({}, {
			__index = function()
				return package_root
			end,
		}),
	}
end

local function seed_file(path, contents)
	paths.write(paths.join(paths.home, path), contents)
end

-- Conflict detection through the real assembler.
do
	local function plan_for(...)
		return source.plan(application_for(...))
	end
	assert_fails("unknown provider", function()
		plan_for({ ["x"] = { { provider = "mystery", spec = {} } } })
	end)
	assert_fails("duplicate exclusive target", function()
		plan_for({
			["a"] = { provision.chezmoi({ target = ".conflict", kind = "file", content = "a\n" }) },
			["b"] = { provision.chezmoi({ target = ".conflict", kind = "file", content = "b\n" }) },
		})
	end)
	assert_fails("declared as file but also contains", function()
		plan_for({
			["a"] = { provision.chezmoi({ target = ".parent", kind = "file", content = "a\n" }) },
			["b"] = { provision.chezmoi({ target = ".parent/child", kind = "file", content = "b\n" }) },
		})
	end)
	assert_fails("incompatible directory attributes", function()
		plan_for({
			["a"] = { provision.chezmoi({ target = ".shared", kind = "directory", private = true }) },
			["b"] = { provision.chezmoi({ target = ".shared", kind = "directory" }) },
		})
	end)
	assert_fails("overlaps owned target", function()
		plan_for({
			["a"] = { provision.chezmoi({ target = ".gone", kind = "remove" }) },
			["b"] = { provision.chezmoi({ target = ".gone/inner", kind = "file", content = "x\n" }) },
		})
	end)
	assert_fails("overlaps engine-private state", function()
		plan_for({
			["a"] = { provision.chezmoi({ target = ".local/state/workstation/x", kind = "file", content = "x\n" }) },
		})
	end)
	assert_fails("contains cross-owner target", function()
		plan_for({
			["a"] = { provision.chezmoi({ target = ".exact", kind = "directory", exact = true }) },
			["b"] = { provision.chezmoi({ target = ".exact/inner", kind = "file", content = "x\n" }) },
		})
	end)
	-- Same-owner children inside an exact container follow the documented
	-- exact contract; only cross-owner content is rejected.
	local exact_plan = plan_for({
		["a"] = {
			provision.chezmoi({ target = ".exact", kind = "directory", exact = true }),
			provision.chezmoi({ target = ".exact/inner", kind = "file", content = "x\n" }),
		},
	})
	assert(#exact_plan.entries == 2, "same-owner exact children were rejected")
	assert_fails("encompasses engine-private state", function()
		plan_for({
			["a"] = {
				provision.chezmoi({ target = ".local", kind = "directory", exact = true }),
				provision.chezmoi({ target = ".local/owned", kind = "file", content = "x\n" }),
			},
		})
	end)
	-- compatible shared directories merge and share attribution
	local plan = plan_for({
		["a"] = { provision.chezmoi({ target = ".shared", kind = "directory", private = true }) },
		["b"] = { provision.chezmoi({ target = ".shared", kind = "directory", private = true }) },
	})
	assert(#plan.entries == 1 and #plan.entries[1].attribution == 2, "shared directories did not merge")
	-- asset confinement: traversal and symlinked components are rejected
	assert_fails("must not traverse", function()
		plan_for({
			["a"] = { provision.chezmoi({ target = ".escape", kind = "file", asset = "../../etc/passwd" }) },
		})
	end)
	paths.write(paths.join(package_root, "real-asset"), "real\n")
	assert(vim.uv.fs_symlink("/etc/hostname", paths.join(package_root, "asset-link")))
	assert_fails("not a regular entry", function()
		plan_for({ ["a"] = { provision.chezmoi({ target = ".via-link", kind = "file", asset = "asset-link" }) } })
	end)
	vim.fn.delete(paths.join(package_root, "asset-link"))
	-- a confined real asset resolves through the plan
	local plan = plan_for({ ["a"] = { provision.chezmoi({ target = ".real", kind = "file", asset = "real-asset" }) } })
	assert(plan.entries[1].bytes == "real\n", "confined asset bytes missing")
	assert_fails("asset is missing", function()
		plan_for({ ["a"] = { provision.chezmoi({ target = ".missing", kind = "file", asset = "no-such-asset" }) } })
	end)
	-- the same target cannot be both fragment-composed and whole-file owned
	assert_fails("duplicate exclusive target", function()
		plan_for({
			["a"] = {
				provision.shell({ target = ".bashrc", fragment = { id = "f", marker = "# f", body = "f", order = 1 } }),
			},
			["b"] = { provision.chezmoi({ target = ".bashrc", kind = "file", content = "whole\n" }) },
		})
	end)
end

-- Deterministic generation ids and deduplicated publication.
do
	local function entries()
		return {
			provision.chezmoi({ target = ".gen-a", kind = "file", content = "a\n" }),
			provision.chezmoi({ target = ".gen-b", kind = "symlink", to = "gen-a" }),
		}
	end
	local first = source.plan(application_for({ ["a"] = entries() }))
	local second = source.plan(application_for({ ["a"] = entries() }))
	assert(first.generation == second.generation, "generation id is not deterministic")
	-- journal-free plans are independent of collection-map order
	local reversed = source.plan(application_for({ ["b"] = entries() }))
	assert(reversed.generation == first.generation, "generation depends on package identity")
	local provisioner = require("workstation.provisioner")
	local directory = provisioner.publish(first)
	assert(vim.uv.fs_stat(directory), "generation was not published")
	assert(provisioner.publish(second) == directory, "identical generation was not deduplicated")
	-- a damaged cached generation is quarantined and republished, never trusted
	local victim = paths.join(directory, "dot_gen-a")
	paths.write(victim, "tampered\n")
	local republished = provisioner.publish(second)
	assert(republished == directory, "generation path changed after quarantine")
	assert(paths.read(victim) == "a\n", "damaged generation bytes were reused")
	local quarantined = false
	for name in vim.fs.dir(state.generations_root()) do
		if name:find(".invalid", 1, true) then
			quarantined = true
		end
	end
	assert(quarantined, "damaged generation was not quarantined")
end

-- Fail-closed lock: contention refuses and release only affects own token.
do
	local lock = state.acquire_lock("test")
	assert(lock and lock.token)
	local ok, failure = pcall(state.acquire_lock, "second")
	assert(not ok and tostring(failure):find("locked by another operation", 1, true), "contending lock was taken")
	assert(paths.exists(lock.path))
	lock:release()
	assert(not paths.exists(lock.path), "own lock was not released")
	-- stale lock content is reported for inspected operator recovery
	paths.write(paths.join(state.root(), "apply.lock"), '{"token":"stale"}')
	local ok2, failure2 = pcall(state.acquire_lock, "third")
	assert(not ok2 and tostring(failure2):find("stale", 1, true), "stale lock metadata not reported")
	vim.fn.delete(paths.join(state.root(), "apply.lock"))
	-- with_lock releases only its own lock on failure
	local before = paths.exists(paths.join(state.root(), "apply.lock"))
	assert(not before)
	local ok3 = pcall(state.with_lock, "failing", function()
		error("boom")
	end)
	assert(not ok3)
	assert(not paths.exists(paths.join(state.root(), "apply.lock")), "failed operation retained the lock")
end

print("provider contract tests passed (recipes, encoding, conflicts, composition, generations, locks)")
