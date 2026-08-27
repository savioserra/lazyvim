local commands = require("workstation.commands")

local M = {}

local function font_directory(context)
	return context.paths.join(
		vim.env.LOCALAPPDATA or context.paths.join(context.paths.home, "AppData", "Local"),
		"Microsoft",
		"Windows",
		"Fonts",
		"JetBrainsMonoNerdFont"
	)
end

function M.configure(context)
	local directory = font_directory(context)
	assert(context.paths.exists(directory), "JetBrainsMono Nerd Font directory is missing: " .. directory)
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
]]):format(directory:gsub("'", "''"))
	commands.execute("powershell.exe", { "-NoProfile", "-NonInteractive", "-Command", script })
end

function M.verify(context)
	local directory = font_directory(context)
	local count = 0
	for name in vim.fs.dir(directory) do
		if name:sub(-4) == ".ttf" then
			count = count + 1
		end
	end
	assert(count > 0, "No JetBrainsMono Nerd Font files installed")
	local registry =
		commands.capture("reg.exe", { "query", "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts" }):lower()
	local registered = 0
	for line in registry:gsub("\\", "/"):gmatch("[^\r\n]+") do
		if line:find(directory:lower(), 1, true) then
			registered = registered + 1
		end
	end
	assert(registered == count, ("Expected %d registered fonts, got %d"):format(count, registered))
end

return M
