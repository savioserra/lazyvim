local M = {}

local function validate_string_list(values, label)
	assert(type(values) == "table", label .. " must be a list")
	for index, value in ipairs(values) do
		assert(type(value) == "string" and value ~= "", ("%s[%d] must be a non-empty string"):format(label, index))
	end
end

local function validate_cases(cases, fields, label)
	assert(type(cases) == "table", label .. " must be a list")
	for index, case in ipairs(cases) do
		assert(type(case) == "table", ("%s[%d] must be a table"):format(label, index))
		for _, field in ipairs(fields) do
			assert(
				type(case[field]) == "string" and case[field] ~= "",
				("%s[%d].%s must be a non-empty string"):format(label, index, field)
			)
		end
	end
end

---Validate one language profile contribution in isolation.
function M.validate_entry(contribution, label)
	label = label or ("Neovim profile entry " .. tostring(contribution and contribution.id))
	assert(type(contribution) == "table", label .. " must be a table")
	assert(type(contribution.id) == "string" and contribution.id ~= "", label .. ".id must be a non-empty string")
	assert(
		contribution.plugin_module == nil
			or (type(contribution.plugin_module) == "string" and contribution.plugin_module ~= ""),
		label .. ".plugin_module must be a non-empty string"
	)
	validate_string_list(contribution.requires or {}, label .. ".requires")
	validate_string_list(contribution.lazyvim_extras or {}, label .. ".lazyvim_extras")
	validate_string_list(contribution.mason_packages or {}, label .. ".mason_packages")
	validate_cases(
		contribution.language_cases or {},
		{ "language", "filename", "contents", "client" },
		label .. ".language_cases"
	)
	validate_cases(
		contribution.formatter_cases or {},
		{ "language", "filename", "contents", "expected" },
		label .. ".formatter_cases"
	)
	return contribution
end

function M.validate(profile)
	assert(type(profile) == "table", "Neovim profile must be a list")
	local ids = {}
	for index, contribution in ipairs(profile) do
		local label = ("Neovim profile[%d]"):format(index)
		M.validate_entry(contribution, label)
		assert(not ids[contribution.id], "duplicate Neovim profile contribution: " .. contribution.id)
		ids[contribution.id] = true
	end
	return profile
end

local function validate_order(order)
	assert(
		type(order) == "number" and order > 0 and order % 1 == 0,
		"Neovim profile recipe requires a positive integer order"
	)
end

---Pure recipe constructor for one nvim-owned profile intent. `order` fixes the
---composed import sequence explicitly (Go, TypeScript, standard) instead of
---relying on incidental graph or hash iteration order.
function M.recipe(options)
	assert(type(options) == "table", "Neovim profile recipe requires an options table")
	for field in pairs(options) do
		assert(field == "entry" or field == "order", "Neovim profile recipe has unknown option " .. tostring(field))
	end
	validate_order(options.order)
	assert(type(options.entry) == "table", "Neovim profile recipe requires an entry table")
	M.validate_entry(options.entry, "Neovim profile recipe entry")
	return {
		provider = "nvim-profile",
		spec = {
			order = options.order,
			entry = vim.deepcopy(options.entry),
		},
	}
end

---Validate a materialized nvim-profile spec at collection time.
function M.validate_spec(spec)
	validate_order(spec.order)
	M.validate_entry(spec.entry, "Neovim profile entry " .. tostring(spec.entry and spec.entry.id))
end

function M.required_capabilities(profile)
	local required, seen = {}, {}
	for _, contribution in ipairs(profile) do
		for _, capability in ipairs(contribution.requires or {}) do
			if not seen[capability] then
				seen[capability] = true
				table.insert(required, capability)
			end
		end
	end
	return required
end

local function quote(value)
	-- %q keeps strings valid Lua source; fold its literal-newline escapes back
	-- onto one line so every serialized field stays a single readable line.
	return (string.format("%q", value):gsub("\\\n", "\\n"))
end

local function serialize_list(values)
	local parts = {}
	for _, value in ipairs(values) do
		table.insert(parts, quote(value))
	end
	return "{ " .. table.concat(parts, ", ") .. " }"
end

local function serialize_key(name)
	if name:match("^[%w_]+$") then
		return name
	end
	return "[" .. quote(name) .. "]"
end

local function serialize_case(case, fields)
	local parts = {}
	for _, field in ipairs(fields) do
		table.insert(parts, field .. " = " .. quote(case[field]))
	end
	if case.project_files then
		local names = vim.tbl_keys(case.project_files)
		table.sort(names)
		local entries = {}
		for _, name in ipairs(names) do
			table.insert(entries, ("%s = %s"):format(serialize_key(name), quote(case.project_files[name])))
		end
		table.insert(parts, "project_files = { " .. table.concat(entries, ", ") .. " }")
	end
	return "{ " .. table.concat(parts, ", ") .. " }"
end

local function serialize_cases(cases, fields)
	local lines = {}
	for _, case in ipairs(cases) do
		table.insert(lines, "\t\t\t" .. serialize_case(case, fields) .. ",")
	end
	return "{\n" .. table.concat(lines, "\n") .. "\n\t\t}"
end

---Serialize the composed profile as deployed runtime Lua. The deployed file is
---plain editor configuration: no factories, lifecycle modules or engine imports.
function M.serialize(profile)
	M.validate(profile)
	local blocks = {}
	for _, contribution in ipairs(profile) do
		local fields = {}
		table.insert(fields, "\t\tid = " .. quote(contribution.id))
		if contribution.requires then
			table.insert(fields, "\t\trequires = " .. serialize_list(contribution.requires))
		end
		if contribution.lazyvim_extras then
			table.insert(fields, "\t\tlazyvim_extras = " .. serialize_list(contribution.lazyvim_extras))
		end
		if contribution.plugin_module then
			table.insert(fields, "\t\tplugin_module = " .. quote(contribution.plugin_module))
		end
		if contribution.mason_packages then
			table.insert(fields, "\t\tmason_packages = " .. serialize_list(contribution.mason_packages))
		end
		if contribution.language_cases then
			table.insert(
				fields,
				"\t\tlanguage_cases = "
					.. serialize_cases(contribution.language_cases, { "language", "filename", "contents", "client" })
			)
		end
		if contribution.formatter_cases then
			table.insert(
				fields,
				"\t\tformatter_cases = "
					.. serialize_cases(contribution.formatter_cases, { "language", "filename", "contents", "expected" })
			)
		end
		table.insert(blocks, "\t{\n" .. table.concat(fields, ",\n") .. "\n\t},")
	end
	return "return {\n" .. table.concat(blocks, "\n") .. "\n}\n"
end

return M
