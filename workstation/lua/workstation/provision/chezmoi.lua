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

---Normalize a logical target to a clean relative home path.
local function normalize_target(target)
	assert(is_nonempty_string(target), "chezmoi recipe requires a target string")
	assert(target:sub(1, 1) ~= "/", "chezmoi target must be relative to the destination home: " .. target)
	assert(not target:find("\\", 1, true), "chezmoi target must not contain backslashes: " .. target)
	assert(target:sub(-1) ~= "/", "chezmoi target must name a file, not a directory slash: " .. target)
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
	for field in pairs(options) do
		assert(
			vim.list_contains({
				"target",
				"kind",
				"content",
				"asset",
				"executable",
				"private",
				"exact",
				"template",
				"to",
				"fragments",
			}, field),
			"chezmoi recipe has unknown option " .. tostring(field)
		)
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
	assert(options.fragments == nil or type(options.fragments) == "table", "chezmoi fragments must be a list")
	if options.kind == "modify" then
		local has_body = options.content ~= nil or options.asset ~= nil
		assert(
			(has_body and options.fragments == nil) or (not has_body and options.fragments ~= nil),
			"chezmoi modify recipe accepts exactly one whole body or structured fragments"
		)
	elseif options.kind == "remove" then
		assert(
			options.content == nil and options.asset == nil and options.fragments == nil,
			"chezmoi removal recipe accepts no content"
		)
	else
		assert(
			options.kind == "symlink" or options.kind == "directory" or options.content ~= nil or options.asset ~= nil,
			"chezmoi recipe requires content or a package-relative asset"
		)
		assert(options.fragments == nil, "chezmoi fragments are only valid for modify recipes")
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
	if options.fragments ~= nil then
		spec.fragments = {}
		for index, fragment in ipairs(options.fragments) do
			spec.fragments[index] = vim.deepcopy(fragment)
		end
	end
	return { provider = M.id, spec = spec }
end

---Encode one native chezmoi source name component from a logical target
---component. One-way only: conflicts are keyed on normalized targets, never on
---decoded names.
local function source_component(component)
	if component:sub(1, 1) == "." then
		return "dot_" .. component:sub(2)
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
	local prefix = ""
	for index = 1, #spec.components - 1 do
		prefix = index == 1 and spec.components[index] or prefix .. "/" .. spec.components[index]
		local flags = ancestors[prefix] or {}
		local flags_name = ""
		if flags.exact then
			flags_name = flags_name .. "exact_"
		end
		if flags.private then
			flags_name = flags_name .. "private_"
		end
		directory[index] = flags_name .. source_component(spec.components[index])
	end
	local last = source_component(spec.components[#spec.components])
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

---Deep domain validation of a materialized spec at collection time.
function M.validate_spec(spec)
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
		fragments = spec.fragments,
	})
	local components, normalized = normalize_target(spec.target)
	assert(normalized == spec.target, "chezmoi target is not normalized: " .. tostring(spec.target))
	assert(#components == #spec.components, "chezmoi target components changed")
end

---Expected target state for precondition checks, when it is computable from
---the recipe alone. Template bodies are backend-rendered and return nil.
function M.expected_state(spec, bytes)
	if spec.template then
		return nil
	end
	if spec.kind == "file" then
		return { type = "file", sha256 = vim.fn.sha256(bytes) }
	end
	if spec.kind == "symlink" then
		return { type = "link", link = spec.to }
	end
	if spec.kind == "directory" then
		return { type = "directory" }
	end
	return nil
end

return M
