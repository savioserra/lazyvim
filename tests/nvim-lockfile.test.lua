-- lazy-lock.json merge-program behavior: the program deployed by the nvim
-- package through the modify recipe. Seeds the committed engine pin baseline
-- verbatim, asserts engine-pin primacy over drifted copies, preserves host
-- extras with an installed plugin directory, prunes stale extras, fails
-- closed on malformed input, and produces byte-stable output.
local repository = vim.fn.getcwd()
local root = vim.fs.joinpath(repository, "workstation")
package.path = table.concat({
	vim.fs.joinpath(root, "?.lua"),
	vim.fs.joinpath(root, "?", "init.lua"),
	vim.fs.joinpath(root, "lua", "?.lua"),
	vim.fs.joinpath(root, "lua", "?", "init.lua"),
	package.path,
}, ";")

local paths = require("workstation.paths")

local package_root = vim.fs.joinpath(root, "packages", "nvim")
local function read(relative)
	local file = assert(io.open(vim.fs.joinpath(package_root, relative), "rb"))
	local contents = file:read("*a")
	file:close()
	return contents
end

local pins = read("files/.config/nvim/lazy-lock.json")

-- Model the bootstrap guarantee the program relies on: the canonical managed
-- Neovim path inside this fixture home. -l mode exposes no vim.v0: resolve
-- the running binary instead.
local running = vim.uv.fs_readlink("/proc/self/exe")
if not (running and vim.uv.fs_stat(running)) then
	running = vim.fn.resolve(vim.fn.exepath("nvim"))
end
assert(running and vim.fn.executable(running) == 1, "cannot resolve the running Neovim")
local nvim_dest = paths.join(paths.local_dir, "opt", "nvim", "bin", "nvim")
vim.fn.mkdir(vim.fs.dirname(nvim_dest), "p")
assert(vim.uv.fs_symlink(running, nvim_dest))

-- The contribution embeds the committed pins verbatim into the program body.
local context = require("workstation.context").create()
local program
for _, envelope in ipairs(require("packages.nvim")({ context = context }).contributes) do
	if envelope.provider == "chezmoi" and envelope.spec.target == ".config/nvim/lazy-lock.json" then
		assert(envelope.spec.kind == "modify", "lazy-lock recipe stopped being a modify program")
		assert(envelope.spec.executable == true, "lazy-lock program must deploy as executable")
		program = envelope.spec.content
	end
end
assert(program, "nvim package no longer contributes a lazy-lock.json recipe")
assert(program:find(pins:sub(1, 200), 1, true), "committed engine pins were not embedded verbatim")

local script = vim.fn.tempname()
paths.write(script, program)
local function run(input)
	local result = vim.system({ "sh", script }, { stdin = input, text = false }):wait()
	return result.code, result.stdout, result.stderr
end

-- The program locates plugin directories exactly like a deployed runtime:
-- the Neovim data root under this fixture HOME.
local lazy_root = paths.join(vim.env.XDG_DATA_HOME or paths.join(paths.local_dir, "share"), "nvim", "lazy")

-- Absent/empty target: the engine baseline seeds verbatim.
local code, out = run("")
assert(code == 0, "seed run failed: " .. tostring(out))
assert(out == pins, "seeded bytes differ from the committed asset")

-- Already-converged target: verbatim fast path, zero churn.
code, out = run(pins)
assert(code == 0 and out == pins, "converged input was rewritten")

-- lazy.nvim-style drift: a host extra recorded before its directory existed.
local extra_line = '  "aether": { "branch": "v3", "commit": "567efb778534e11ee1072d4fe27178f705a27d8a" },'
local drifted = pins:gsub('  "blink.cmp"', extra_line .. '\n  "blink.cmp"', 1)
assert(drifted ~= pins, "fixture drift insertion failed")

-- Stale extra without an installed plugin directory: pruned to the baseline.
code, out = run(drifted)
assert(code == 0 and out == pins, "stale extra was preserved")

-- Installed extra: preserved, and the result round-trips byte-identically.
vim.fn.mkdir(paths.join(lazy_root, "aether"), "p")
code, out = run(drifted)
assert(code == 0, "merge over an installed extra failed: " .. tostring(out))
local decoded = vim.json.decode(out)
assert(
	decoded.aether and decoded.aether.commit == "567efb778534e11ee1072d4fe27178f705a27d8a",
	"installed host extra was dropped"
)
assert(
	out == pins:gsub('  "blink.cmp"', extra_line .. '\n  "blink.cmp"', 1),
	"merged output is not the expected serialization"
)
local code_again, out_again = run(out)
assert(code_again == 0 and out_again == out, "merged output is not byte-stable under a second run")

-- Diverged engine pin: the engine pin wins unconditionally.
local tampered = pins:gsub('("LazyVim": %{ "branch": "main", "commit": ")%x+', "%1deadbeef", 1)
assert(tampered ~= pins, "fixture tamper substitution failed")
code, out = run(tampered)
assert(code == 0 and out == pins, "diverged engine pin was not restored")

-- Tampered pin AND extra together: engine restored; the extra is pruned
-- again once its plugin directory is gone (stale in the same run).
vim.fn.delete(paths.join(lazy_root, "aether"), "rf")
code, out = run(tampered:gsub('  "blink.cmp"', extra_line .. '\n  "blink.cmp"', 1))
assert(code == 0 and out == pins, "combined drift did not converge to the baseline")

-- Malformed deployed state fails closed instead of being replaced.
code = run("{ not json")
assert(code ~= 0, "malformed deployed lockfile was silently accepted")

print("nvim-lockfile: merge program seeds, reconciles, prunes and fails closed")
