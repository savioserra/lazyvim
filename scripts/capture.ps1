[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Path
)

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

Write-DotfilesLog 'Capturing managed configuration changes'
$arguments = @('--source', $RepoRoot, '--destination', $HOME, 're-add')
if ($null -ne $Path -and $Path.Count -gt 0) {
    $arguments += $Path
}
Invoke-NativeCommand -FilePath $Chezmoi -Arguments $arguments
Write-DotfilesLog 'Capture complete; review the repository diff before committing.'
