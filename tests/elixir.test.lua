-- Canonical gate lane for the Elixir umbrella. Runs the real mix suite only
-- when the checkout is warm, so cold clones and nested meta-checks keep the
-- gate's time bound; skips print their reason and exit 0. mise resolves the
-- pinned toolchain (and its bundled MIX_HOME) through the real data dir, which
-- the per-suite fixture HOME would hide — check.sh exports
-- WORKSTATION_MISE_DATA_DIR and test-home.sh passes the marker through.
local repository = vim.fn.getcwd()
local elixir = repository .. "/elixir"

local function entries(path)
	local stat = vim.uv.fs_stat(path)
	if not stat or stat.type ~= "directory" then
		return 0
	end
	local count = 0
	for _ in vim.fs.dir(path) do
		count = count + 1
	end
	return count
end

-- Returns nil when the suite ran, or the skip reason.
local function main()
	if vim.env.WORKSTATION_NESTED_CHECK then
		return "nested check keeps its time bound"
	end
	if vim.fn.executable("mise") ~= 1 then
		return "mise is not on PATH"
	end
	local isolated = vim.env.WORKSTATION_HOME ~= nil and vim.env.WORKSTATION_HOME == vim.env.HOME
	local data = vim.env.WORKSTATION_MISE_DATA_DIR or vim.env.MISE_DATA_DIR
	local env = {}
	if data and data ~= "" and vim.uv.fs_stat(data) then
		env.MISE_DATA_DIR = data
	elseif isolated then
		return "isolated check.sh run without WORKSTATION_MISE_DATA_DIR"
	end
	if entries(elixir .. "/deps") == 0 then
		return "deps are cold; run mise exec -- mix deps.get in elixir/ once"
	end
	if entries(elixir .. "/_build/test/lib") == 0 then
		return "_build is cold; run mise exec -- mix test in elixir/ once"
	end
	local result = vim.system({ "mise", "exec", "--", "mix", "test" }, {
		cwd = elixir,
		env = env,
		text = true,
		timeout = 300000,
	}):wait()
	assert(result.code == 0, "mix test failed:\n" .. tostring(result.stdout) .. tostring(result.stderr))
end

local reason = main()
if reason then
	print("elixir mix tests skipped (" .. reason .. ")")
else
	print("elixir mix tests passed (umbrella suite)")
end
