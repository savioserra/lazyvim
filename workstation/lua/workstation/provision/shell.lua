local M = {}

-- The shared-shell compositor. Capabilities contribute stable, individually
-- owned fragments (marker + literal single-line body) to shared shell startup
-- files; this provider composes one native chezmoi modify program per target in
-- a deterministic order. Retiring a fragment removes exactly its recorded
-- marker+body block and never the whole transformed file. Arbitrary user
-- modifiers are never concatenated or reversed here.

M.id = "shell"

local function is_nonempty_string(value)
	return type(value) == "string" and value ~= ""
end

local function validate_fragment(fragment)
	assert(type(fragment) == "table", "shell fragment must be a table")
	for field in pairs(fragment) do
		assert(
			vim.list_contains({ "id", "marker", "body", "order" }, field),
			"shell fragment has unknown field " .. tostring(field)
		)
	end
	assert(is_nonempty_string(fragment.id), "shell fragment requires an id")
	assert(is_nonempty_string(fragment.marker), "shell fragment requires a marker")
	assert(is_nonempty_string(fragment.body), "shell fragment requires a body")
	assert(
		type(fragment.order) == "number" and fragment.order > 0 and fragment.order % 1 == 0,
		"shell fragment requires a positive integer order"
	)
	assert(not fragment.marker:find("[\r\n]"), "shell fragment marker must be a single line")
	assert(not fragment.body:find("[\r\n]"), "shell fragment body must be a single line")
end

local function validate_target(target)
	assert(is_nonempty_string(target), "shell recipe requires a target")
	assert(target:sub(1, 1) ~= "/", "shell target must be relative to the destination home: " .. target)
	assert(not target:find("\\", 1, true), "shell target must not contain backslashes: " .. target)
	for component in target:gmatch("[^/]+") do
		assert(component ~= "." and component ~= "..", "shell target must not traverse: " .. target)
	end
end

---Pure recipe constructor: one owned fragment for one shared shell target.
function M.recipe(options)
	assert(type(options) == "table", "shell recipe requires an options table")
	for field in pairs(options) do
		assert(
			vim.list_contains({ "target", "fragment" }, field),
			"shell recipe has unknown option " .. tostring(field)
		)
	end
	validate_target(options.target)
	validate_fragment(options.fragment)
	local components = {}
	for component in options.target:gmatch("[^/]+") do
		table.insert(components, component)
	end
	return {
		provider = M.id,
		spec = {
			target = table.concat(components, "/"),
			components = components,
			fragment = {
				id = options.fragment.id,
				marker = options.fragment.marker,
				body = options.fragment.body,
				order = options.fragment.order,
			},
		},
	}
end

function M.validate_spec(spec)
	validate_target(spec.target)
	validate_fragment(spec.fragment)
end

local function shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Escape a single-line string as an awk double-quoted literal.
local function awk_quote(value)
	return '"' .. value:gsub('[\\"]', "\\%0") .. '"'
end

-- Build the exact-block removal for one retired fragment. The generated awk
-- program removes a marker line followed by exactly the recorded body line
-- (plus the blank line the composer emits before a block) and fails on an
-- edited or duplicated block instead of guessing.
local function removal_program(marker, body)
	local program = table.concat({
		"BEGIN { m = " .. awk_quote(marker) .. "; b = " .. awk_quote(body) .. "; found = 0; bad = 0 }",
		"{ lines[NR] = $0 }",
		"END {",
		"  for (i = 1; i <= NR; i++) {",
		"    if (lines[i] == m) {",
		"      if (i < NR && lines[i + 1] == b) {",
		"        found++; i++",
		'        if (out > 0 && text[out] == "") out--',
		"      } else { bad = 1 }",
		"    } else { text[++out] = lines[i] }",
		"  }",
		"  for (i = 1; i <= out; i++) print text[i]",
		"  if (bad || found > 1) exit 70",
		"}",
	}, "\n") .. "\n"
	-- Failures are explicit exits: POSIX set -e ignores failures of commands
	-- that are not the last element of an AND-OR list, so a conflict must not
	-- rely on it.
	return "awk " .. shell_quote(program) .. ' "$work" >"$work.next" || exit 70\n  mv "$work.next" "$work" || exit 70'
end

---Compose the native modify program for one shared target.
---@param desired table[] ordered fragment records {id, marker, body}
---@param retired table[] fragment records previously applied but no longer declared
---@return string program, string[] ids
function M.compose(target, desired, retired)
	assert(#desired + #retired > 0, "shell composition requires at least one fragment: " .. target)
	-- Explicit fragment order with graph collection order as the stable
	-- tie-breaker keeps the emitted block sequence deterministic.
	local ordered = {}
	for index, fragment in ipairs(desired) do
		ordered[index] =
			{ order = fragment.order or 0, marker = fragment.marker, body = fragment.body, id = fragment.id }
	end
	for index, fragment in ipairs(ordered) do
		fragment.sequence = index
	end
	table.sort(ordered, function(left, right)
		if left.order ~= right.order then
			return left.order < right.order
		end
		return left.sequence < right.sequence
	end)
	local lines = {
		"#!/usr/bin/env sh",
		"# Managed by the workstation engine; do not edit deployed shared state by hand.",
		"# Owned fragments: " .. table.concat(
			vim.tbl_map(function(fragment)
				return fragment.id
			end, ordered),
			", "
		),
		"# Emit shell expressions literally for future shells, never evaluate at render time.",
		"# shellcheck disable=SC2016",
		"set -eu",
		'work="$(mktemp)"',
		'trap \'rm -f "$work" "$work.next"\' EXIT HUP INT TERM',
		'cat >"$work"',
	}
	for _, fragment in ipairs(retired) do
		table.insert(lines, "# retire fragment " .. fragment.id .. ": remove its exact known block")
		table.insert(lines, "if grep -Fqx " .. shell_quote(fragment.marker) .. ' "$work"; then')
		table.insert(lines, "  " .. removal_program(fragment.marker, fragment.body))
		table.insert(lines, "fi")
	end
	for _, fragment in ipairs(ordered) do
		table.insert(lines, "if ! grep -Fqx " .. shell_quote(fragment.marker) .. ' "$work"; then')
		table.insert(
			lines,
			"  printf '\\n%s\\n%s\\n' "
				.. shell_quote(fragment.marker)
				.. " "
				.. shell_quote(fragment.body)
				.. ' >>"$work"'
		)
		table.insert(lines, "fi")
	end
	table.insert(lines, 'cat "$work"')
	local ids = {}
	for index, fragment in ipairs(ordered) do
		ids[index] = fragment.id
	end
	return table.concat(lines, "\n") .. "\n", ids
end

return M
