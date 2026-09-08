-- Tiny stored ZIP builder for offline provisioning tests; no zip executable
-- or language-runtime bootstrap dependency. Production only reads ZIP archives.
local M = {}
local function little(value, bytes)
	local result = {}
	for _ = 1, bytes do
		table.insert(result, string.char(value % 256))
		value = math.floor(value / 256)
	end
	return table.concat(result)
end
local function crc32(data)
	local crc = 0xffffffff
	for index = 1, #data do
		crc = bit.bxor(crc, data:byte(index))
		for _ = 1, 8 do
			crc = bit.bxor(bit.rshift(crc, 1), bit.band(crc, 1) == 1 and 0xedb88320 or 0)
		end
	end
	return bit.bnot(crc) % 0x100000000
end
function M.write(path, entries)
	local local_records, central_records, offset, count = {}, {}, 0, 0
	local names = vim.tbl_keys(entries)
	table.sort(names)
	for _, name in ipairs(names) do
		local data = entries[name]
		local common = little(20, 2)
			.. little(0, 2)
			.. little(0, 2)
			.. little(0, 2)
			.. little(33, 2)
			.. little(crc32(data), 4)
			.. little(#data, 4)
			.. little(#data, 4)
			.. little(#name, 2)
			.. little(0, 2)
		local record = "PK\003\004" .. common .. name .. data
		table.insert(local_records, record)
		table.insert(
			central_records,
			"PK\001\002"
				.. little(20, 2)
				.. common
				.. little(0, 2)
				.. little(0, 2)
				.. little(0, 2)
				.. little(0, 4)
				.. little(offset, 4)
				.. name
		)
		offset, count = offset + #record, count + 1
	end
	local central = table.concat(central_records)
	local ending = "PK\005\006"
		.. little(0, 2)
		.. little(0, 2)
		.. little(count, 2)
		.. little(count, 2)
		.. little(#central, 4)
		.. little(offset, 4)
		.. little(0, 2)
	local file = assert(io.open(path, "wb"))
	assert(file:write(table.concat(local_records) .. central .. ending))
	file:close()
end
return M
