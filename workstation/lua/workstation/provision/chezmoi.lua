local M = {}

-- The chezmoi provider: interprets capability-owned recipe options as native
-- chezmoi source state. Recipe construction is pure data only; validation,
-- asset reading and name encoding happen here at consumption time. Chezmoi
-- itself renders templates and executes modifiers; this module never renders
-- template syntax, decodes source names or executes anything.

M.id = "chezmoi"

local kinds = { file = true, directory = true, symlink = true, modify = true, remove = true }

local function is_nonempty_string(value)
	return type(value) == "string" and value ~= ""
end

---Normalize a logical target to a clean relative home path. Control bytes,
---newlines and NUL are rejected: they cannot survive into generated source
---names or literal removal entries.
local function normalize_target(target)
	assert(is_nonempty_string(target), "chezmoi recipe requires a target string")
	assert(target:sub(1, 1) ~= "/", "chezmoi target must be relative to the destination home: " .. target)
	assert(not target:find("\\", 1, true), "chezmoi target must not contain backslashes: " .. target)
	assert(target:sub(-1) ~= "/", "chezmoi target must name a file, not a directory slash: " .. target)
	assert(
		not target:find("[%c]"),
		"chezmoi target must not contain control characters or newlines: " .. target:gsub("%c", "?")
	)
	local components = {}
	for component in target:gmatch("[^/]+") do
		assert(component ~= "." and component ~= "..", "chezmoi target must not traverse: " .. target)
		table.insert(components, component)
	end
	assert(#components > 0, "chezmoi target is empty")
	return components, table.concat(components, "/")
end

local function validate_options(options)
	assert(type(options) == "table", "chezmoi recipe requires an options table")
	-- Structured fragments are the shell compositor's input alone: accepting
	-- them here would publish an empty modify program and truncate the target.
	assert(options.fragments == nil, "chezmoi recipe rejects structured fragments: they belong to provision.shell only")
	local allowed = {
		target = true,
		kind = true,
		content = true,
		asset = true,
		executable = true,
		private = true,
		exact = true,
		template = true,
		to = true,
	}
	for field in pairs(options) do
		assert(allowed[field], "chezmoi recipe has unknown option " .. tostring(field))
	end
	assert(is_nonempty_string(options.target), "chezmoi recipe requires a target")
	assert(kinds[options.kind], "chezmoi recipe has unsupported kind " .. tostring(options.kind))
	assert(
		options.content == nil or is_nonempty_string(options.content),
		"chezmoi recipe content must be a non-empty string"
	)
	assert(options.asset == nil or is_nonempty_string(options.asset), "chezmoi recipe asset must be a non-empty string")
	for _, flag in ipairs({ "executable", "private", "exact", "template" }) do
		assert(
			options[flag] == nil or type(options[flag]) == "boolean",
			"chezmoi recipe " .. flag .. " must be boolean"
		)
	end
	assert(
		options.content == nil or options.asset == nil,
		"chezmoi recipe accepts exactly one inline body or package-relative asset"
	)
	assert(
		options.to == nil or is_nonempty_string(options.to),
		"chezmoi symlink recipe requires a non-empty link destination"
	)
	assert(options.to == nil or options.kind == "symlink", "chezmoi recipe option to is only valid for symlinks")
	assert(
		options.kind ~= "symlink" or (options.to ~= nil and options.content == nil and options.asset == nil),
		"chezmoi symlink recipe requires exactly a link destination"
	)
	if options.kind == "modify" then
		assert(
			options.content ~= nil or options.asset ~= nil,
			"chezmoi modify recipe requires one whole body or package-relative asset"
		)
	elseif options.kind == "remove" then
		assert(options.content == nil and options.asset == nil, "chezmoi removal recipe accepts no content")
	else
		assert(
			options.kind == "symlink" or options.kind == "directory" or options.content ~= nil or options.asset ~= nil,
			"chezmoi recipe requires content or a package-relative asset"
		)
	end
	assert(
		options.executable == nil or options.executable == true,
		"chezmoi recipe executable cannot be disabled; remove the option"
	)
	assert(
		options.kind == "symlink" or options.private == nil or options.private == true,
		"chezmoi recipe private cannot be disabled; remove the option"
	)
	assert(
		options.kind == "symlink" or options.exact == nil or options.exact == true,
		"chezmoi recipe exact cannot be disabled; remove the option"
	)
	assert(
		options.kind == "directory" or options.exact == nil,
		"chezmoi recipe exact is only representable for directories"
	)
	assert(
		options.kind ~= "symlink" or (options.executable == nil and options.private == nil),
		"chezmoi symlinks take no executable or private attributes"
	)
	assert(
		options.kind ~= "remove" or (options.executable == nil and options.private == nil and options.template == nil),
		"chezmoi removals take no attributes"
	)
	assert(options.kind ~= "directory" or options.template == nil, "chezmoi directories cannot be templates")
end

---Pure recipe constructor: `provision.chezmoi(opts)`. Returns copied plain data
---without I/O, target writes or registration.
function M.recipe(options)
	validate_options(options)
	local components, normalized = normalize_target(options.target)
	for index, component in ipairs(components) do
		M.source_component(component, index == #components, options.template == true)
	end
	if options.kind == "symlink" and options.to:sub(1, 1) ~= "/" then
		-- Declared destinations may be absolute anywhere without being
		-- dereferenced here, but relative destinations must resolve inside the
		-- destination home rather than escaping it.
		local depth = #components - 1
		for component in options.to:gmatch("[^/]+") do
			if component == ".." then
				depth = depth - 1
				assert(depth >= 0, "chezmoi symlink destination escapes the destination home: " .. options.to)
			end
		end
	end
	local spec = {
		target = normalized,
		components = components,
		kind = options.kind,
		executable = options.executable,
		private = options.private,
		exact = options.exact,
		template = options.template,
	}
	if options.content ~= nil then
		spec.content = options.content
	elseif options.asset ~= nil then
		spec.asset = options.asset
	end
	if options.to ~= nil then
		spec.to = options.to
	end
	return { provider = M.id, spec = spec }
end

-- Chezmoi attribute keywords change the decoded kind/target of a source name.
-- A literal logical component that already carries one of these prefixes would
-- be re-interpreted by the backend (for example a home file literally named
-- "dot_profile" or "modify_tool"), so such components are rejected fail-closed
-- instead of guessed at. No decoder is implemented.
local reserved_component_prefixes = {
	"dot_",
	"create_",
	"modify_",
	"once_",
	"run_",
	"private_",
	"executable_",
	"symlink_",
	"exact_",
	"remove_",
	"empty_",
	"encrypted_",
}

---Encode one native chezmoi source name component from a logical target
---component. One-way only: conflicts are keyed on normalized targets, never on
---decoded names. Ambiguous components that the backend would decode
---differently are rejected, at construction and at collection.
function M.source_component(component, is_final, template)
	if component:sub(1, 1) == "." then
		return "dot_" .. component:sub(2)
	end
	for _, prefix in ipairs(reserved_component_prefixes) do
		assert(
			not vim.startswith(component, prefix),
			("chezmoi target component %q is not representable as native source state (reserved prefix %s)"):format(
				component,
				prefix
			)
		)
	end
	if component:find("%.tmpl$") then
		assert(
			is_final and template,
			"chezmoi target component ending in .tmpl is only representable as the intended template itself: "
				.. component
		)
	end
	return component
end

---Native chezmoi source path for a validated spec, e.g.
---`.profile` + modify + executable -> `modify_executable_dot_profile`.
---`ancestors` maps an intermediate logical target to the attribute flags of its
---declared owning directory recipe, so children of a private directory encode
---`private_` on that component exactly as chezmoi source names require.
---Explicit removals have no source name; they become `.chezmoiremove` entries.
function M.source_name(spec, ancestors)
	assert(spec.kind ~= "remove", "removal recipes have no chezmoi source name")
	ancestors = ancestors or {}
	local directory = {}
	local walked = ""
	for index = 1, #spec.components - 1 do
		walked = index == 1 and spec.components[index] or walked .. "/" .. spec.components[index]
		local flags = ancestors[walked] or {}
		local flags_name = ""
		if flags.exact then
			flags_name = flags_name .. "exact_"
		end
		if flags.private then
			flags_name = flags_name .. "private_"
		end
		directory[index] = flags_name .. M.source_component(spec.components[index], false, false)
	end
	local last = M.source_component(spec.components[#spec.components], true, spec.template)
	assert(
		spec.template or not last:find("%.tmpl$"),
		"chezmoi target ending in .tmpl requires template = true: " .. spec.target
	)
	local flags = {}
	if spec.kind == "symlink" then
		flags[#flags + 1] = "symlink"
	elseif spec.kind == "directory" then
		if spec.exact then
			flags[#flags + 1] = "exact"
		end
		if spec.private then
			flags[#flags + 1] = "private"
		end
	else
		if spec.private then
			flags[#flags + 1] = "private"
		end
		if spec.executable then
			flags[#flags + 1] = "executable"
		end
	end
	local prefix = ""
	if spec.kind == "modify" then
		prefix = "modify_"
	end
	if #flags > 0 then
		prefix = prefix .. table.concat(flags, "_") .. "_"
	end
	local suffix = spec.template and ".tmpl" or ""
	return (#directory > 0 and table.concat(directory, "/") .. "/" or "") .. prefix .. last .. suffix
end

-- Full required mode metadata for change sets; chezmoi only distinguishes
-- private/executable, and arbitrary POSIX modes are rejected as unrepresentable.
-- Proven with the trusted backend: private files are 0600, executable files
-- 0755, and private+executable files 0700 (owner-only, never group/world).
function M.entry_mode(spec)
	if spec.kind == "symlink" then
		return nil
	end
	if spec.kind == "directory" then
		return spec.private and 448 or 493
	end
	if spec.executable then
		return spec.private and 448 or 493
	end
	return spec.private and 384 or 420
end

---Read a confined package-relative asset. The asset must stay inside the owner
---root, name only directories and one final regular file, and never traverse a
---symlink out of the declared owning root.
local function read_asset(owner_root, asset)
	assert(is_nonempty_string(asset), "chezmoi recipe asset must be a non-empty string")
	assert(asset:sub(1, 1) ~= "/", "chezmoi asset must be package-relative: " .. asset)
	local current = owner_root
	for component in asset:gmatch("[^/]+") do
		assert(component ~= "." and component ~= "..", "chezmoi asset must not traverse: " .. asset)
		current = current .. "/" .. component
		local stat = assert(vim.uv.fs_lstat(current), "chezmoi asset is missing: " .. owner_root .. "/" .. asset)
		assert(stat.type == "directory" or stat.type == "file", "chezmoi asset component is not a regular entry")
	end
	local stat = assert(vim.uv.fs_lstat(current), "chezmoi asset is missing: " .. owner_root .. "/" .. asset)
	assert(stat.type == "file", "chezmoi asset must be a regular file: " .. owner_root .. "/" .. asset)
	local file = assert(io.open(current, "rb"))
	local contents = file:read("*a")
	file:close()
	assert(is_nonempty_string(contents), "chezmoi asset is empty: " .. owner_root .. "/" .. asset)
	return contents
end

---Resolve the source bytes for a validated spec, reading a confined asset when
---declared. Returns nil for entries without a body.
function M.source_bytes(spec, owner_root)
	if spec.content ~= nil then
		return spec.content
	end
	if spec.asset ~= nil then
		return read_asset(owner_root, spec.asset)
	end
	return nil
end

---Deep domain validation of a materialized spec at collection time. A
---mutated or hand-built envelope cannot redirect the generated path: unknown
---fields are rejected and every derived component must still re-derive from
---the logical target.
function M.validate_spec(spec)
	assert(type(spec) == "table", "chezmoi spec must be a table")
	assert(type(spec.target) == "string", "chezmoi spec requires a target string")
	local allowed = {
		target = true,
		components = true,
		kind = true,
		content = true,
		asset = true,
		executable = true,
		private = true,
		exact = true,
		template = true,
		to = true,
	}
	for field in pairs(spec) do
		assert(allowed[field], "chezmoi spec has unknown field " .. tostring(field))
	end
	validate_options({
		target = spec.target,
		kind = spec.kind,
		content = spec.content,
		asset = spec.asset,
		executable = spec.executable,
		private = spec.private,
		exact = spec.exact,
		template = spec.template,
		to = spec.to,
	})
	local components, normalized = normalize_target(spec.target)
	assert(normalized == spec.target, "chezmoi target is not normalized: " .. tostring(spec.target))
	assert(type(spec.components) == "table" and #spec.components == #components, "chezmoi target components changed")
	for index, component in ipairs(components) do
		assert(
			spec.components[index] == component,
			("chezmoi target component %d does not re-derive from %s"):format(index, spec.target)
		)
	end
end

---Expected target state for precondition checks, when it is computable from
---the recipe alone: full required mode plus type/content/link identity.
---Template bodies are backend-rendered and return nil.
function M.expected_state(spec, bytes)
	if spec.template then
		return nil
	end
	if spec.kind == "file" then
		return { type = "file", sha256 = vim.fn.sha256(bytes), mode = M.entry_mode(spec) }
	end
	if spec.kind == "symlink" then
		return { type = "link", link = spec.to }
	end
	if spec.kind == "directory" then
		return { type = "directory", mode = M.entry_mode(spec) }
	end
	return nil
end

return M
