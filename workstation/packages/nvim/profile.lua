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

function M.validate(profile)
	assert(type(profile) == "table", "Neovim profile must be a list")
	local ids = {}
	for index, contribution in ipairs(profile) do
		local label = ("Neovim profile[%d]"):format(index)
		assert(type(contribution) == "table", label .. " must be a table")
		assert(type(contribution.id) == "string" and contribution.id ~= "", label .. ".id must be a non-empty string")
		assert(not ids[contribution.id], "duplicate Neovim profile contribution: " .. contribution.id)
		ids[contribution.id] = true
		validate_string_list(contribution.requires or {}, label .. ".requires")
		validate_string_list(contribution.lazyvim_extras or {}, label .. ".lazyvim_extras")
		validate_string_list(contribution.mason_packages or {}, label .. ".mason_packages")
		assert(
			contribution.plugin_module == nil
				or (type(contribution.plugin_module) == "string" and contribution.plugin_module ~= ""),
			label .. ".plugin_module must be a non-empty string"
		)
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
	end
	return profile
end

function M.load(context)
	local path = context.paths.join(context.paths.home, ".config", "nvim", "lua", "languages", "profile.lua")
	return M.validate(assert(loadfile(path))())
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

return M
