param([Parameter(Mandatory)][string]$ScratchHome)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$env:HOME = $ScratchHome
$env:USERPROFILE = $ScratchHome
$env:LOCALAPPDATA = Join-Path $ScratchHome 'AppData/Local'
$env:CHEZMOI_DESTDIR = $ScratchHome
$env:CHEZMOI_SYNC_APPLY_ONLY = '1'

New-Item -ItemType Directory -Force -Path $ScratchHome | Out-Null
& "$repoRoot\sync.ps1"

function Assert-Output($Actual, $Expected) {
  if ($Actual -ne $Expected) { throw "Expected '$Expected', got '$Actual'" }
}

Assert-Output ((& "$ScratchHome\.local\opt\nvim\bin\nvim.exe" --version | Select-Object -First 1)) 'NVIM v0.12.4'
if (-not ((& "$ScratchHome\.local\opt\go\bin\go.exe" version) -like 'go version go1.27.0*')) { throw 'Unexpected Go version' }
Assert-Output ((& "$ScratchHome\.local\opt\nvm-windows\nvm.exe" version)) '1.2.2'
Assert-Output ((& "$ScratchHome\.local\opt\nvm-windows\nodejs\node.exe" --version)) 'v24.19.0'
Assert-Output ((& "$ScratchHome\.local\bin\rg.exe" --version | Select-Object -First 1)) 'ripgrep 15.2.0'
if (-not ((& "$ScratchHome\.local\bin\fd.exe" --version) -like 'fd 10.*')) { throw 'Unexpected fd version' }
if (-not ((& "$ScratchHome\.local\bin\fzf.exe" --version) -like '0.74.2*')) { throw 'Unexpected fzf version' }
if (-not ((& "$ScratchHome\.local\bin\lazygit.exe" --version) -match 'version=0\.63\.1')) { throw 'Unexpected lazygit version' }
if (-not ((& "$ScratchHome\.local\bin\tree-sitter.exe" --version) -match '0\.26\.11')) { throw 'Unexpected tree-sitter version' }

$fontDir = Join-Path $ScratchHome 'AppData\Local\Microsoft\Windows\Fonts\JetBrainsMonoNerdFont'
$fontEntries = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts').PSObject.Properties |
  Where-Object { $_.Name -match '^JetBrainsMonoNerdFont' -and $_.Value -like "$fontDir*" }
if ($fontEntries.Count -ne 96) { throw "Expected 96 registered fonts, got $($fontEntries.Count)" }
