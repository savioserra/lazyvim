-- The lazy-lock.json merge: Neovim records the active spec set into the
-- deployed lockfile, which may include host-provided specs. An absent or
-- empty lockfile gets the committed baseline; otherwise the baseline pins
-- win on conflict, host extras with an installed plugin directory stay, the
-- rest are pruned. Input that is not a JSON object fails closed.
local baseline_json = [===[__WORKSTATION_LAZY_LOCK_BASELINE__]===]

local canonical_fields = { "branch", "build", "commit", "version", "semver", "pinned" }

local function fail(message)
	io.stderr:write("lazy-lock merge: " .. message .. "\n")
	io.stderr:flush()
	os.exit(1)
end

local function json_string(value)
	if type(value) ~= "string" then
		return tostring(value)
	end
	local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\t"] = "\\t", ["\r"] = "\\r" }
	return '"' .. value:gsub('[%c"\\]', function(char)
		return escapes[char] or ("\\u%04X"):format(char:byte())
	end) .. '"'
end

-- Serialize in lazy.nvim's lockfile shape: ASCII-sorted names, one line per
-- entry, canonical field order, so converged output byte-matches what lazy
-- itself writes for the same pin set.
local function write_lockfile(pins)
	local names = {}
	for name in pairs(pins) do
		names[#names + 1] = name
	end
	table.sort(names)
	local lines = { "{" }
	for index, name in ipairs(names) do
		local entry = pins[name]
		local known = {}
		for _, field in ipairs(canonical_fields) do
			known[field] = true
		end
		local fields = {}
		local ordered = {}
		for _, field in ipairs(canonical_fields) do
			ordered[#ordered + 1] = field
		end
		local unknown = {}
		for field in pairs(entry) do
			if not known[field] then
				unknown[#unknown + 1] = field
			end
		end
		table.sort(unknown)
		for _, field in ipairs(unknown) do
			ordered[#ordered + 1] = field
		end
		for _, field in ipairs(ordered) do
			local value = entry[field]
			if value ~= nil then
				fields[#fields + 1] = ('"%s": %s'):format(field, json_string(value))
			end
		end
		lines[#lines + 1] = ('  %s: { %s }%s'):format(json_string(name), table.concat(fields, ", "), index < #names and "," or "")
	end
	lines[#lines + 1] = "}"
	io.stdout:write(table.concat(lines, "\n") .. "\n")
end

local deployed_json = io.read("*a") or ""
if deployed_json == "" or deployed_json == baseline_json then
	io.stdout:write(baseline_json)
	return
end

local ok_deployed, deployed = pcall(vim.json.decode, deployed_json)
if not ok_deployed or type(deployed) ~= "table" then
	fail("deployed lazy-lock.json is not a JSON object")
end
local ok_baseline, baseline = pcall(vim.json.decode, baseline_json)
if not ok_baseline or type(baseline) ~= "table" then
	fail("the embedded baseline is not a JSON object")
end

local data_root = vim.env.XDG_DATA_HOME or ((vim.env.HOME or "") .. "/.local/share")
local lazy_root = data_root .. "/nvim/lazy"

local merged = {}
for name, pin in pairs(baseline) do
	merged[name] = pin
end
for name, pin in pairs(deployed) do
	if merged[name] == nil and vim.uv.fs_stat(lazy_root .. "/" .. name) then
		merged[name] = pin
	end
end
write_lockfile(merged)
