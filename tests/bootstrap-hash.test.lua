-- Run the actual bootstrap suite with each native-only prerequisite PATH. The
-- host needs just one implementation; adapters here model the other host name.
local repository = vim.fn.getcwd()
local scratch = vim.fn.tempname()
local function write(path, contents)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	vim.fn.writefile(vim.split(contents, "\n", { plain = true }), path)
	assert(vim.uv.fs_chmod(path, 448))
end
local implementation = vim.fn.exepath("sha256sum")
local arguments = ""
if implementation == "" then
	implementation = vim.fn.exepath("shasum")
	arguments = " -a 256"
end
assert(implementation ~= "", "requires sha256sum or shasum")
for _, native in ipairs({ "sha256sum", "shasum" }) do
	local bin = scratch .. "/" .. native
	vim.fn.mkdir(bin, "p")
	for _, name in ipairs({
		"sh",
		"env",
		"mktemp",
		"dirname",
		"readlink",
		"mkdir",
		"chmod",
		"cut",
		"rm",
		"sleep",
		"cp",
		"gzip",
		"tar",
		"mv",
	}) do
		local executable = vim.fn.exepath(name)
		assert(executable ~= "", "missing prerequisite: " .. name)
		assert(vim.uv.fs_symlink(executable, bin .. "/" .. name))
	end
	local strip = native == "shasum" and '[ "$1" = -a ] && [ "$2" = 256 ] || exit 2\nshift 2\n' or ""
	write(
		bin .. "/" .. native,
		"#!/bin/sh\n" .. strip .. "exec " .. vim.fn.shellescape(implementation) .. arguments .. ' "$@"\n'
	)
	local missing = native == "sha256sum" and "shasum" or "sha256sum"
	local probe = scratch .. "/" .. native .. ".lua"
	write(
		probe,
		string.format(
			[[
assert(vim.env.PATH == %q)
assert(vim.fn.exepath(%q) == %q)
assert(vim.fn.exepath(%q) == "", "non-native hash escaped controlled PATH")
assert(vim.fn.executable("node") == 0 and vim.fn.executable("nvim") == 0)
dofile(%q)
assert(vim.fn.exepath(%q) == "", "fixture adapter leaked into parent PATH")
print(%q)
]],
			bin,
			native,
			bin .. "/" .. native,
			missing,
			repository .. "/tests/bootstrap.test.lua",
			missing,
			native .. "-only PATH passed; " .. missing .. " absent outside bootstrap adapters"
		)
	)
	local result = vim.system({ "sh", repository .. "/.github/scripts/test-home.sh", vim.v.progpath, "-l", probe }, {
		env = { PATH = bin },
		clear_env = true,
		text = true,
	}):wait()
	local log = vim.env.HOME .. "/bootstrap-hash-evidence/" .. native
	write(log .. ".stdout", result.stdout)
	write(log .. ".stderr", result.stderr)
	write(log .. ".exit", tostring(result.code))
	assert(result.code == 0, native .. ": " .. result.stdout .. result.stderr)
	print(result.stdout .. result.stderr)
end
vim.fn.delete(scratch, "rf")
print("bootstrap hash portability tests passed (single implementation, both native-only PATHs; simulated hosts)")
