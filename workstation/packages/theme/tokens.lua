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
-- border_roles is the closed set of dashboard border roles, one per panel
-- domain: border_engine/border_plan (blue, the engine-core forward views),
-- border_journal/border_status (green, health-log semantics),
-- border_capabilities (yellow, pending-apply caution), border_diff (red,
-- the mutation surface). All values reuse existing palette hues.
--
-- Roles are the API, values are data: no consumer template may hardcode a
-- literal color or slot name for a role carried here. Re-branding edits only
-- this file.

-- Brand: Starlight (oasis.nvim starlight @thm_* tokens), dark palette from
-- themes/dark/oasis_starlight_dark.conf, light from the light_3 sibling
-- (upstream default intensity). Judgment calls (chrome/muted split,
-- selected_bg, light muted) per the rebrand spec S-R3.
M.version = 4

M.slots = {
	accent = "blue",
	ok = "green",
	warn = "yellow",
	err = "red",
	chrome = "brightblack",
	text = "white",
	shortcut = "magenta",
	selected_bg = "brightblack",
	selected_fg = "white",
	inactive = "brightblack",
	ramp_start = "green",
	ramp_mid = "yellow",
	ramp_end = "red",
	border_engine = "blue",
	border_journal = "green",
	border_capabilities = "yellow",
	border_plan = "blue",
	border_diff = "red",
	border_status = "green",
}

M.palette = {
	dark = {
		accent = "#5badff",
		ok = "#7fcf78",
		warn = "#f0e68c",
		err = "#ff7979",
		chrome = "#4f5b6b",
		text = "#f5f5dc",
		shortcut = "#c695ff",
		selected_bg = "#4d4528",
		selected_fg = "#f5f5dc",
		inactive = "#4f5b6b",
		ramp_start = "#7fcf78",
		ramp_mid = "#f0e68c",
		ramp_end = "#ff7979",
		border_engine = "#5badff",
		border_journal = "#7fcf78",
		border_capabilities = "#f0e68c",
		border_plan = "#5badff",
		border_diff = "#ff7979",
		border_status = "#7fcf78",
		bg = "#000000",
		muted = "#666666",
	},
	light = {
		accent = "#023c75",
		ok = "#3b6837",
		warn = "#665f22",
		err = "#bc1313",
		chrome = "#50463e",
		text = "#181811",
		shortcut = "#7d2adc",
		selected_bg = "#e1d8c1",
		selected_fg = "#181811",
		inactive = "#50463e",
		ramp_start = "#3b6837",
		ramp_mid = "#665f22",
		ramp_end = "#bc1313",
		border_engine = "#023c75",
		border_journal = "#3b6837",
		border_capabilities = "#665f22",
		border_plan = "#023c75",
		border_diff = "#bc1313",
		border_status = "#3b6837",
		bg = "#f5f2ea",
		muted = "#50463e",
	},
}

M.consumers = {
	herdr = { name = "terminal", auto_switch = true },
}

-- Role order is the emission order for every derived artifact; new roles
-- append after the base six: keyboard/selection affordances (shortcut,
-- selected pair, inactive), the magnitude ramp trio start->mid->end, then
-- the per-domain border roles.
local slot_roles = { "accent", "ok", "warn", "err", "chrome", "text", "shortcut", "selected_bg", "selected_fg", "inactive", "ramp_start", "ramp_mid", "ramp_end", "border_engine", "border_journal", "border_capabilities", "border_plan", "border_diff", "border_status" }
local palette_roles = { "accent", "ok", "warn", "err", "chrome", "text", "shortcut", "selected_bg", "selected_fg", "inactive", "ramp_start", "ramp_mid", "ramp_end", "border_engine", "border_journal", "border_capabilities", "border_plan", "border_diff", "border_status", "bg", "muted" }
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
