local M = {}

local function trim(value)
	return value:match("^[ \t]*(.-)[ \t]*$")
end

local function validate_bytes(contents)
	for index = 1, #contents do
		local byte = contents:byte(index)
		assert(byte < 0x7f, "non-ASCII bytes are unsupported in managed TOML")
		if byte < 0x20 then
			local permitted = byte == 0x09 or byte == 0x0a or (byte == 0x0d and contents:byte(index + 1) == 0x0a)
			assert(permitted, "forbidden whitespace or control byte in managed TOML")
		end
	end
end

local function strip_comment(line)
	local quoted = false
	local escaped = false
	for index = 1, #line do
		local character = line:sub(index, index)
		if quoted and escaped then
			escaped = false
		elseif quoted and character == "\\" then
			escaped = true
		elseif character == '"' then
			quoted = not quoted
		elseif not quoted and character == "#" then
			return line:sub(1, index - 1)
		end
	end
	assert(not quoted and not escaped, "unsupported or unterminated TOML string")
	return line
end

local function basic_string(value)
	if not value:match('^".*"$') then
		return false
	end
	local body = value:sub(2, -2)
	assert(not body:find("[\r\n]"), "multiline TOML strings are unsupported")
	local index = 1
	while index <= #body do
		local byte = body:byte(index)
		assert(byte >= 0x20 and byte ~= 0x7f, "control characters in TOML strings are unsupported")
		if body:sub(index, index) == "\\" then
			local escape = body:sub(index + 1, index + 1)
			assert(escape:find('^[btnfr"\\]$'), "unsupported TOML string escape")
			index = index + 2
		else
			assert(body:sub(index, index) ~= '"', "unescaped quote in TOML string")
			index = index + 1
		end
	end
	return true
end

local function decimal_integer(value)
	if value == "0" then
		return true
	end
	local negative_digits = value:match("^%-([1-9][0-9]*)$")
	local digits = negative_digits or value:match("^([1-9][0-9]*)$")
	if not digits then
		return false
	end
	local limit = negative_digits and "9223372036854775808" or "9223372036854775807"
	return #digits < #limit or (#digits == #limit and digits <= limit)
end

local function supported_value(value)
	if value == "true" or value == "false" or decimal_integer(value) or basic_string(value) then
		return true
	end
	if value:match("^%[.*%]$") then
		local body = trim(value:sub(2, -2))
		if body == "" then
			return true
		end
		for item in (body .. ","):gmatch("(.-),") do
			assert(basic_string(trim(item)), "only arrays of single-line basic strings are supported")
		end
		return true
	end
	return false
end

-- verify_inactive deliberately recognizes only the repository-managed TOML
-- subset: bare single-component tables/keys and one-line boolean, decimal
-- integer, basic-string, or basic-string-array values. It is not general TOML.
local function flags(contents)
	local section = ""
	local service, hosted, remoting = false, false, false
	for line in (contents .. "\n"):gmatch("(.-)\r?\n") do
		local clean = trim(strip_comment(line))
		local header = clean:match("^%[([A-Za-z_][A-Za-z0-9_-]*)%]$")
		if header then
			section = header
		else
			local key, value = clean:match("^([A-Za-z_][A-Za-z0-9_-]*)[ \t]*=[ \t]*(.-)[ \t]*$")
			if key == "enabled" then
				if section == "service" then
					service = value == "true"
				elseif section == "hosted_pi" then
					hosted = value == "true"
				elseif section == "remoting" then
					remoting = value == "true"
				end
			end
		end
	end
	return service, hosted, remoting
end
function M.activation_flags(contents)
	return flags(contents)
end
function M.verify_managed_active(contents)
	assert(type(contents) == "string", "subagents config must be text")
	validate_bytes(contents)
	local table_name = ""
	local tables = {}
	local definitions = {}
	local service_enabled = nil
	local hosted_pi_enabled = nil
	local remoting_enabled = nil
	local remoting_values = {}
	local peer_tables = 0
	for raw_line in (contents .. "\n"):gmatch("(.-)\r?\n") do
		assert(
			not raw_line:find("'''", 1, true) and not raw_line:find('"""', 1, true),
			"multiline TOML strings are unsupported"
		)
		local line = trim(strip_comment(raw_line))
		if line ~= "" then
			local array_header = line:match("^%[%[([A-Za-z_][A-Za-z0-9_-]*%.[A-Za-z_][A-Za-z0-9_-]*)%]%]$")
			local header = line:match("^%[([A-Za-z_][A-Za-z0-9_-]*)%]$")
			if array_header then
				assert(array_header == "remoting.peers", "unsupported TOML array table: " .. array_header)
				peer_tables = peer_tables + 1
				table_name = array_header .. "#" .. peer_tables
			elseif header then
				assert(not definitions[header], "duplicate or redefined TOML table/key is unsupported: " .. header)
				definitions[header] = "table"
				tables[header] = true
				table_name = header
			else
				assert(line:sub(1, 1) ~= "[", "unsupported TOML table syntax")
				local key, value = line:match("^([A-Za-z_][A-Za-z0-9_-]*)[ \t]*=[ \t]*(.-)[ \t]*$")
				assert(key and value ~= "", "malformed or unsupported TOML assignment")
				assert(supported_value(value), "unsupported TOML value for " .. key)
				local path = table_name == "" and key or table_name .. "." .. key
				assert(not definitions[path], "duplicate or redefined TOML table/key is unsupported: " .. path)
				assert(not tables[key], "TOML key conflicts with an existing table: " .. key)
				definitions[path] = "key"
				if table_name == "service" and key == "enabled" then
					service_enabled = value
				elseif table_name == "hosted_pi" and key == "enabled" then
					hosted_pi_enabled = value
				elseif table_name == "remoting" then
					remoting_values[key] = value
					if key == "enabled" then
						remoting_enabled = value
					end
				end
			end
		end
	end
	assert(tables.service and service_enabled == "true", "repository-managed subagents [service].enabled must be true")
	assert(
		tables.hosted_pi and hosted_pi_enabled == "true",
		"repository-managed subagents [hosted_pi].enabled must be true"
	)
	if remoting_enabled == "true" then
		assert(remoting_values.mode == '"cluster"', "managed remoting mode must be cluster")
		assert(remoting_values.network_trust == '"tailscale"', "managed remoting network trust must be tailscale")
		assert(remoting_values.allowed_cidrs == '["100.64.0.0/10"]', "managed remoting CIDR must be Tailscale IPv4")
		assert(remoting_values.address_families == '["ipv4"]', "managed remoting must use IPv4")
		assert(peer_tables == 2, "managed cluster nodes must configure exactly two peers")
	else
		assert(remoting_enabled == "false", "managed remoting enabled flag must be explicit")
	end
end

M.verify_inactive = M.verify_managed_active

return M
