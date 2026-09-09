-- Minimal stored ustar fixture: arbitrary header names without creating unsafe
-- filesystem paths. Inert regular files or links only; no external generator.
local M = {}
function M.write(path, name, body, link)
	assert(#name <= 100 and #(link or "") <= 100)
	local function field(value, width)
		return value .. string.rep("\0", width - #value)
	end
	local header = field(name, 100)
		.. "0000644\0"
		.. "0000000\0"
		.. "0000000\0"
		.. ("%011o\0"):format(#body)
		.. "00000000000\0"
		.. string.rep(" ", 8)
		.. (link and "2" or "0")
		.. field(link or "", 100)
		.. "ustar\0"
		.. "00"
		.. string.rep("\0", 247)
	assert(#header == 512)
	local sum = 0
	for i = 1, #header do
		sum = sum + header:byte(i)
	end
	header = header:sub(1, 148) .. ("%06o\0 "):format(sum) .. header:sub(157)
	local file = assert(io.open(path, "wb"))
	file:write(header, body, string.rep("\0", (512 - #body % 512) % 512 + 1024))
	file:close()
end
return M
