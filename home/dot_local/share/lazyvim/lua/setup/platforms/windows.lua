local commands = require("setup.commands")
local paths = require("setup.paths")
local versions = require("setup.versions")

local M = { name = "win32" }
local nvm_dir = paths.join(paths.local_dir, "opt", "nvm-windows")
local active_node_dir = paths.join(nvm_dir, "nodejs")
local font_dir = paths.join(
	vim.env.LOCALAPPDATA or paths.join(paths.home, "AppData", "Local"),
	"Microsoft",
	"Windows",
	"Fonts",
	"JetBrainsMonoNerdFont"
)
M.node = paths.join(active_node_dir, "node.exe")
M.nvim = paths.join(paths.local_dir, "opt", "nvim", "bin", "nvim.exe")

function M.nvim_data()
	if vim.env.XDG_DATA_HOME and vim.env.XDG_DATA_HOME ~= "" then
		return paths.join(vim.env.XDG_DATA_HOME, "nvim")
	end
	return paths.join(vim.env.LOCALAPPDATA or paths.join(paths.home, "AppData", "Local"), "nvim-data")
end

function M.tool(name)
	if name == "go" then
		return paths.join(paths.local_dir, "opt", "go", "bin", "go.exe")
	end
	return paths.join(paths.local_dir, "bin", name .. ".exe")
end

local function read_user_environment(name)
	local ok, output = pcall(commands.capture, "reg.exe", { "query", "HKCU\\Environment", "/v", name })
	if not ok then
		return ""
	end
	for line in output:gmatch("[^\r\n]+") do
		if vim.trim(line):sub(1, #name) == name then
			return vim.trim(line:match("REG_EXPAND_SZ%s+(.+)") or line:match("REG_SZ%s+(.+)") or "")
		end
	end
	return ""
end

local function write_user_environment(name, value, expandable)
	if read_user_environment(name) == value then
		return
	end
	commands.execute(
		"reg.exe",
		{ "add", "HKCU\\Environment", "/v", name, "/t", expandable and "REG_EXPAND_SZ" or "REG_SZ", "/d", value, "/f" }
	)
end

local function path_key(path)
	return path:gsub("\\", "/"):gsub("/+$", ""):lower()
end

---@param current string
---@param required string[]
---@return string
function M.merge_path(current, required)
	local managed = {}
	for _, entry in ipairs(required) do
		managed[path_key(entry)] = true
	end

	local result, seen = {}, {}
	local function add(entry)
		local key = path_key(entry)
		if key ~= "" and not seen[key] then
			seen[key] = true
			table.insert(result, entry)
		end
	end
	for _, entry in ipairs(required) do
		add(entry)
	end
	for _, entry in ipairs(vim.split(current, ";", { trimempty = true })) do
		if not managed[path_key(entry)] then
			add(entry)
		end
	end
	return table.concat(result, ";")
end

function M.configure_runtime()
	vim.env.NVM_HOME = nvm_dir
	vim.env.NVM_SYMLINK = active_node_dir
	vim.env.PATH = table.concat({
		paths.join(paths.local_dir, "bin"),
		vim.fs.dirname(M.nvim),
		vim.fs.dirname(M.tool("go")),
		nvm_dir,
		active_node_dir,
		vim.env.PATH or "",
	}, ";")
end

function M.configure_node()
	M.configure_runtime()
	paths.write(
		paths.join(nvm_dir, "settings.txt"),
		("root: %s\r\npath: %s\r\narch: 64\r\nproxy: none\r\n"):format(nvm_dir, active_node_dir)
	)
	local active_ok, active_version = pcall(commands.capture, M.node, { "--version" })
	if not active_ok or active_version ~= "v" .. versions.node then
		commands.execute(paths.join(nvm_dir, "nvm.exe"), { "use", versions.node }, { timeout = 30000 })
	end
	local required = {
		paths.join(paths.local_dir, "bin"),
		vim.fs.dirname(M.nvim),
		vim.fs.dirname(M.tool("go")),
		nvm_dir,
		active_node_dir,
	}
	write_user_environment("Path", M.merge_path(read_user_environment("Path"), required), true)
	write_user_environment("XDG_CONFIG_HOME", paths.join(paths.home, ".config"))
	write_user_environment("NVM_HOME", nvm_dir)
	write_user_environment("NVM_SYMLINK", active_node_dir)
end

function M.verify_node()
	assert(
		commands.capture(paths.join(nvm_dir, "nvm.exe"), { "version" }) == versions.nvm_windows,
		"Unexpected nvm-windows version"
	)
	local persisted_path = read_user_environment("Path")
	local resolved =
		vim.split(commands.capture("where.exe", { "node.exe" }, { env = { PATH = persisted_path } }), "\n")[1]
	assert(
		path_key(resolved) == path_key(M.node),
		("Persisted user PATH resolves %s instead of %s"):format(resolved, M.node)
	)
end

function M.configure_fonts()
	assert(paths.exists(font_dir), "JetBrainsMono Nerd Font directory is missing: " .. font_dir)
	local script = ([[
$fontDirectory = '%s'
$registryPath = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
New-Item -Path $registryPath -Force | Out-Null
Get-ItemProperty -LiteralPath $registryPath | ForEach-Object { $_.PSObject.Properties } | Where-Object { $_.Name -like 'JetBrainsMono*' -or ($_.Value -is [string] -and $_.Value.StartsWith($fontDirectory, [StringComparison]::OrdinalIgnoreCase)) } | ForEach-Object { Remove-ItemProperty -LiteralPath $registryPath -Name $_.Name -ErrorAction SilentlyContinue }
Get-ChildItem -LiteralPath $fontDirectory -Filter '*.ttf' | ForEach-Object { New-ItemProperty -LiteralPath $registryPath -Name ($_.BaseName + ' (TrueType)') -Value $_.FullName -PropertyType String -Force | Out-Null }
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class FontRegistration {
[DllImport("gdi32.dll", CharSet=CharSet.Unicode)] public static extern int AddFontResourceEx(string f,uint flags,IntPtr r);
[DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h,uint m,UIntPtr w,IntPtr l,uint f,uint t,out UIntPtr r);
}
'@
Get-ChildItem -LiteralPath $fontDirectory -Filter '*.ttf' | ForEach-Object { [void][FontRegistration]::AddFontResourceEx($_.FullName,0,[IntPtr]::Zero) }
$result=[UIntPtr]::Zero; [void][FontRegistration]::SendMessageTimeout([IntPtr]0xffff,0x001d,[UIntPtr]::Zero,[IntPtr]::Zero,2,5000,[ref]$result)
]]):format(font_dir:gsub("'", "''"))
	commands.execute("powershell.exe", { "-NoProfile", "-NonInteractive", "-Command", script })
end

function M.verify_fonts()
	local count = 0
	for name in vim.fs.dir(font_dir) do
		if name:sub(-4) == ".ttf" then
			count = count + 1
		end
	end
	assert(count > 0, "No JetBrainsMono Nerd Font files installed")
	local registry =
		commands.capture("reg.exe", { "query", "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts" }):lower()
	local registered = 0
	for line in registry:gsub("\\", "/"):gmatch("[^\r\n]+") do
		if line:find(font_dir:lower(), 1, true) then
			registered = registered + 1
		end
	end
	assert(registered == count, ("Expected %d registered fonts, got %d"):format(count, registered))
end

return M
