local M = {}

-- The shared-shell compositor. Capabilities contribute stable, individually
-- owned fragments (marker + literal single-line body) to shared shell startup
-- files; this provider composes one native chezmoi modify program per target in
-- a deterministic order. Every owned block - retained, replaced or retiring -
-- is verified against the exact recorded marker+body pair: edited, duplicated
-- or ambiguous blocks conflict instead of being overwritten or silently kept,
-- and the journal can only ever claim ownership of bytes that were actually
-- installed. Arbitrary user modifiers are never concatenated or reversed here.

M.id = "shell"

local function is_nonempty_string(value)
	return type(value) == "string" and value ~= ""
end

local function reject_control(value, label)
	assert(not value:find("[%c]"), label .. " must not contain control characters or newlines")
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
	-- Ids, markers and bodies are embedded in generated shell comments and
	-- programs; control bytes and newlines could not survive literally.
	reject_control(fragment.id, "shell fragment id")
	reject_control(fragment.marker, "shell fragment marker")
	reject_control(fragment.body, "shell fragment body")
end

local function validate_target(target)
	assert(is_nonempty_string(target), "shell recipe requires a target")
	assert(target:sub(1, 1) ~= "/", "shell target must be relative to the destination home: " .. target)
	assert(not target:find("\\", 1, true), "shell target must not contain backslashes: " .. target)
	assert(not target:find("[%c]"), "shell target must not contain control characters or newlines")
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

---Validate a materialized shell spec at collection time: the derived
---components must re-derive from the logical target.
function M.validate_spec(spec)
	validate_target(spec.target)
	validate_fragment(spec.fragment)
	local components = {}
	for component in spec.target:gmatch("[^/]+") do
		table.insert(components, component)
	end
	assert(#components == #spec.components, "shell target components changed")
	for index, component in ipairs(components) do
		assert(spec.components[index] == component, "shell target component does not re-derive")
	end
end

local function shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Escape a single-line string as an awk double-quoted literal.
local function awk_quote(value)
	return '"' .. value:gsub('[\\"]', "\\%0") .. '"'
end

-- Build the exact-block removal for one retiring or replaced fragment. The
-- generated awk program removes a marker line followed by exactly the recorded
-- body line (plus the blank line the composer emits before a block) and fails
-- on an edited or duplicated block instead of guessing.
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

-- Build the verification for one retained or newly appended fragment: when the
-- marker is present it must appear exactly once, followed by exactly the
-- expected body. Anything else is an edited, duplicated or ambiguous owned
-- block and conflicts.
local function verification_program(marker, body)
	local program = table.concat({
		"BEGIN { m = " .. awk_quote(marker) .. "; b = " .. awk_quote(body) .. "; count = 0; bad = 0 }",
		"{ lines[NR] = $0 }",
		"END {",
		"  for (i = 1; i <= NR; i++) {",
		"    if (lines[i] == m) {",
		"      count++",
		"      if (i < NR && lines[i + 1] == b) { i++ } else { bad = 1 }",
		"    }",
		"  }",
		"  if (bad || count > 1) exit 70",
		"}",
	}, "\n") .. "\n"
	return "awk " .. shell_quote(program) .. ' "$work" || exit 70'
end

---Compute the exact-block removals a composition needs: retiring fragments and
---the recorded old blocks of same-id fragments whose body changed.
---@param desired table[] ordered fragment records {id, marker, body, order}
---@param recorded table map id -> previously applied {id, marker, body}
---@return table[] removals, table[] replacements
local function planned_removals(desired, recorded)
	local removals, replacements, kept = {}, {}, {}
	for _, fragment in ipairs(desired) do
		local prior = recorded[fragment.id]
		if prior then
			if prior.marker ~= fragment.marker or prior.body ~= fragment.body then
				-- Same-id declaration change: remove the exact old block first,
				-- then the normal append path installs the new one.
				table.insert(removals, prior)
				table.insert(replacements, fragment)
			else
				kept[fragment.id] = true
			end
		else
			kept[fragment.id] = true
		end
	end
	for id, prior in pairs(recorded) do
		if not kept[id] then
			table.insert(removals, prior)
		end
	end
	table.sort(removals, function(left, right)
		return left.id < right.id
	end)
	return removals, replacements
end

---Compose the native modify program for one shared target.
---@param target string
---@param desired table[] ordered fragment records {id, marker, body, order}
---@param recorded table map id -> previously applied fragment record
---@return string program, string[] ids
function M.compose(target, desired, recorded)
	assert(#desired + vim.tbl_count(recorded or {}) > 0, "shell composition requires at least one fragment: " .. target)
	recorded = recorded or {}
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
	local removals = planned_removals(ordered, recorded)
	local ids = {}
	local markers = {}
	for index, fragment in ipairs(ordered) do
		assert(
			not markers[fragment.marker],
			"duplicate shell marker owned by two fragments on " .. target .. ": " .. fragment.marker
		)
		markers[fragment.marker] = fragment.id
		ids[index] = fragment.id
	end
	local lines = {
		"#!/usr/bin/env sh",
		"# Managed by the workstation engine; do not edit deployed shared state by hand.",
		"# Owned fragments: " .. table.concat(ids, ", "),
		"# Emit shell expressions literally for future shells, never evaluate at render time.",
		"# shellcheck disable=SC2016",
		"set -eu",
		'work="$(mktemp)"',
		'trap \'rm -f "$work" "$work.next"\' EXIT HUP INT TERM',
		'cat >"$work"',
	}
	for _, fragment in ipairs(removals) do
		table.insert(lines, ("# retire fragment %s: remove its exact recorded block"):format(fragment.id))
		table.insert(lines, "if grep -Fqx " .. shell_quote(fragment.marker) .. ' "$work"; then')
		table.insert(lines, "  " .. removal_program(fragment.marker, fragment.body))
		table.insert(lines, "fi")
	end
	for _, fragment in ipairs(ordered) do
		table.insert(lines, "if grep -Fqx " .. shell_quote(fragment.marker) .. ' "$work"; then')
		table.insert(lines, "  " .. verification_program(fragment.marker, fragment.body))
		table.insert(lines, "else")
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
	return table.concat(lines, "\n") .. "\n", ids
end

---Pre-backend validation of one shared target's current content against the
---composed intent. Mirrors the generated programs so an edited, duplicated or
---ambiguous owned block conflicts before the backend mutates anything.
---@param target_path string absolute path of the existing shared file
---@param desired table[] ordered fragment records
---@param recorded table map id -> previously applied fragment record
---@return boolean ok, string? conflict
function M.validate_target(target_path, desired, recorded)
	recorded = recorded or {}
	local file = io.open(target_path, "rb")
	if not file then
		return true
	end
	local lines = {}
	for line in file:lines("L") do
		table.insert(lines, (line:gsub("\r?\n$", "")))
	end
	file:close()
	local removals = planned_removals(desired, recorded)
	local removal_set = {}
	for _, fragment in ipairs(removals) do
		removal_set[fragment.id] = fragment
	end
	local function block_conflict(marker, body, label)
		local count, bad = 0, false
		for index, line in ipairs(lines) do
			if line == marker then
				count = count + 1
				if index < #lines and lines[index + 1] == body then
					-- exact pair
				else
					bad = true
				end
			end
		end
		if count == 0 then
			return nil
		end
		if bad or count > 1 then
			return ("edited, duplicated or ambiguous owned block %s (%s)"):format(label, marker)
		end
		return false
	end
	for _, fragment in ipairs(removals) do
		local verdict = block_conflict(fragment.marker, fragment.body, "to be removed for " .. fragment.id)
		if verdict then
			return false, verdict
		end
	end
	for _, fragment in ipairs(desired) do
		local expected = fragment.body
		if removal_set[fragment.id] then
			-- a replaced fragment still shows its recorded old body right now
			expected = removal_set[fragment.id].body
		end
		local verdict = block_conflict(fragment.marker, expected, "for " .. fragment.id)
		if verdict then
			return false, verdict
		end
	end
	return true
end

return M
