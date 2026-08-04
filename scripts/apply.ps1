[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$RepoRoot = Get-DotfilesRepoRoot
$Tools = Import-ToolManifest (Join-Path $RepoRoot 'manifests\tools.env')
$Chezmoi = if (-not [string]::IsNullOrWhiteSpace($env:CHEZMOI_BIN)) {
    $env:CHEZMOI_BIN
}
else {
    Join-Path (Get-DotfilesOptHome) "chezmoi-$($Tools.CHEZMOI_VERSION)\chezmoi.exe"
}
if (-not (Test-Path -LiteralPath $Chezmoi -PathType Leaf)) {
    throw 'Pinned chezmoi is not installed; run scripts/install-windows.ps1 first.'
}

Write-DotfilesLog 'Applying managed configuration with chezmoi'
Invoke-NativeCommand -FilePath $Chezmoi -Arguments @(
    '--source', $RepoRoot,
    '--destination', $HOME,
    'apply'
)

$managedConfigHome = Join-Path $HOME '.config\nvim'
$configHome = Get-NvimConfigHome
$stateHome = Join-Path $env:LOCALAPPDATA 'dotfiles\state'
$backupRoot = Join-Path $stateHome ("backups\{0}-{1}" -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'), $PID)
$null = New-Item -ItemType Directory -Force -Path $stateHome
Connect-ManagedDirectory -Source $managedConfigHome -Target $configHome -BackupRoot $backupRoot
