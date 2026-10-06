local M = {}

-- The canonical theme token module: the single place where workstation colors
-- are defined. Two layers, both keyed by shared engine role names:
--
--   slots   - role -> terminal NAMED palette slot. Appearance-agnostic by
--             design: the terminal remaps its palette live (OSC 4 retints),
--             so consumers that resolve named slots (tmux2k) follow every
--             terminal theme without any regeneration.
--   palette - role -> concrete color per appearance, for consumers that
--             cannot follow the terminal (rendered UI themes, exports).
--
-- consumers carries canonical choices for surfaces the engine documents but
-- deliberately does not reconfigure (herdr owns its live config.toml).
--
-- Roles are the API, values are data: no consumer template may hardcode a
-- literal color or slot name for a role carried here. Re-branding edits only
-- this file.

M.version = 2

M.slots = {
	accent = "blue",
	ok = "green",
	warn = "yellow",
	err = "red",
	chrome = "brightblack",
	text = "black",
	shortcut = "magenta",
	selected_bg = "blue",
	selected_fg = "black",
	inactive = "brightblack",
	ramp_start = "green",
	ramp_mid = "yellow",
	ramp_end = "red",
}

M.palette = {
	dark = {
		accent = "#7aa2f7",
		ok = "#9ece6a",
		warn = "#e0af68",
		err = "#f7768e",
		chrome = "#414868",
		text = "#c0caf5",
		shortcut = "#bb9af7",
		selected_bg = "#292e42",
		selected_fg = "#c0caf5",
		inactive = "#565f89",
		ramp_start = "#9ece6a",
		ramp_mid = "#e0af68",
		ramp_end = "#f7768e",
		bg = "#1a1b26",
		muted = "#565f89",
	},
	light = {
		accent = "#2e7de9",
		ok = "#587539",
		warn = "#8c6c3e",
		err = "#f52a65",
		chrome = "#a1a6c5",
		text = "#3760bf",
		shortcut = "#7847bd",
		selected_bg = "#cfdaf5",
		selected_fg = "#3760bf",
		inactive = "#6172b0",
		ramp_start = "#587539",
		ramp_mid = "#8c6c3e",
		ramp_end = "#f52a65",
		bg = "#e1e2e7",
		muted = "#6172b0",
	},
}

M.consumers = {
	herdr = { name = "terminal", auto_switch = true },
}

-- Role order is the emission order for every derived artifact; new roles
-- append after the base six: keyboard/selection affordances (shortcut,
-- selected pair, inactive), then the magnitude ramp trio start->mid->end.
local slot_roles = { "accent", "ok", "warn", "err", "chrome", "text", "shortcut", "selected_bg", "selected_fg", "inactive", "ramp_start", "ramp_mid", "ramp_end" }
local palette_roles = { "accent", "ok", "warn", "err", "chrome", "text", "shortcut", "selected_bg", "selected_fg", "inactive", "ramp_start", "ramp_mid", "ramp_end", "bg", "muted" }
local appearances = { "dark", "light" }

-- Terminal NAMED colors tmux2k resolves through the live palette; the same
-- closed set the slot layer is allowed to reference.
local named_slots = {
	black = true,
	red = true,
	green = true,
	yellow = true,
	blue = true,
	magenta = true,
	cyan = true,
	white = true,
	brightblack = true,
	brightred = true,
	brightgreen = true,
	brightyellow = true,
	brightblue = true,
	brightmagenta = true,
	brightcyan = true,
	brightwhite = true,
	default = true,
}

local function toml_string(value)
	assert(type(value) == "string" and value ~= "", "theme token value must be a non-empty string")
	assert(not value:find('[%c\\"]'), "theme token value must be a plain token: " .. value)
	return '"' .. value .. '"'
end

---Fail-closed ordered projection: every listed key must exist, no unlisted
---key may exist, and emission order is the declared list order - never table
---traversal - so the rendered bytes are stable.
local function ordered_pairs(keys, table_value, where)
	local emitted = {}
	for _, key in ipairs(keys) do
		local value = table_value[key]
		assert(value ~= nil, "missing theme " .. where .. ": " .. key)
		emitted[#emitted + 1] = { key, value }
	end
	for key in pairs(table_value) do
		assert(vim.list_contains(keys, key), "unknown theme " .. where .. ": " .. tostring(key))
	end
	return emitted
end

local function valid_hex(value)
	return type(value) == "string"
		and value:match("^#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") ~= nil
end

local function validate()
	ordered_pairs(slot_roles, M.slots, "slot role")
	for _, pair in ipairs(ordered_pairs(slot_roles, M.slots, "slot role")) do
		assert(
			named_slots[pair[2]],
			"theme slot role " .. pair[1] .. " names an unknown terminal slot: " .. tostring(pair[2])
		)
	end
	for _, appearance in ipairs(appearances) do
		local palette = M.palette[appearance]
		assert(type(palette) == "table", "missing theme appearance: " .. appearance)
		for _, pair in ipairs(ordered_pairs(palette_roles, palette, appearance .. " palette role")) do
			assert(
				valid_hex(pair[2]),
				"theme " .. appearance .. " palette role " .. pair[1] .. " must be a #rrggbb color"
			)
		end
	end
	for key in pairs(M.palette) do
		assert(vim.list_contains(appearances, key), "unknown theme appearance: " .. tostring(key))
	end
	local herdr = M.consumers.herdr
	assert(herdr ~= nil and type(herdr.name) == "string" and herdr.name ~= "", "missing herdr consumer choice")
	assert(type(herdr.auto_switch) == "boolean", "herdr consumer auto_switch must be boolean")
	for key in pairs(M.consumers) do
		assert(key == "herdr", "unknown theme consumer: " .. tostring(key))
	end
	for key in pairs(herdr) do
		assert(key == "name" or key == "auto_switch", "unknown herdr consumer field: " .. tostring(key))
	end
end

---Deterministic TOML rendering of the whole token set as the source-root
---`.chezmoidata.toml` envelope. chezmoi merges this file at the template-data
---top level, so templates read `{{ .theme.slots.accent }}` and
---`{{ .theme.palette.dark.accent }}`.
---@return string
function M.chezmoidata()
	validate()
	local lines = {
		"# Generated by the workstation theme capability (packages/theme/tokens.lua).",
		"# Canonical engine roles in two layers: terminal slots for consumers",
		"# that follow the live terminal palette, concrete colors per appearance",
		"# for consumers that cannot. This file is regenerated, never patched.",
		"version = " .. tostring(M.version),
		"",
		"[theme.slots]",
	}
	for _, pair in ipairs(ordered_pairs(slot_roles, M.slots, "slot role")) do
		table.insert(lines, pair[1] .. " = " .. toml_string(pair[2]))
	end
	for _, appearance in ipairs(appearances) do
		table.insert(lines, "")
		table.insert(lines, "[theme.palette." .. appearance .. "]")
		for _, pair in ipairs(ordered_pairs(palette_roles, M.palette[appearance], appearance .. " palette role")) do
			table.insert(lines, pair[1] .. " = " .. toml_string(pair[2]))
		end
	end
	table.insert(lines, "")
	table.insert(lines, "[theme.consumers.herdr]")
	table.insert(lines, "name = " .. toml_string(M.consumers.herdr.name))
	table.insert(lines, "auto_switch = " .. tostring(M.consumers.herdr.auto_switch))
	table.insert(lines, "")
	return table.concat(lines, "\n")
end

return M
