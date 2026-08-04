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
$chezmoiDiff = @(Invoke-NativeCommand -FilePath $Chezmoi -Arguments @(
    '--source', $RepoRoot,
    '--destination', $HOME,
    '--no-pager',
    'diff'
))
if (-not [string]::IsNullOrWhiteSpace(($chezmoiDiff -join "`n"))) {
    throw 'Capture or apply managed configuration changes before syncing.'
}

$changes = & git -C $RepoRoot status --porcelain
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the Git worktree.'
}
if (-not [string]::IsNullOrWhiteSpace(($changes -join "`n"))) {
    throw 'Commit or stash repository changes before syncing.'
}

$upstream = & git -C $RepoRoot rev-parse --abbrev-ref '@{upstream}' 2>$null
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($upstream -join ''))) {
    Write-DotfilesLog 'Pulling configuration changes'
    Invoke-NativeCommand -FilePath 'git' -Arguments @('-C', $RepoRoot, 'pull', '--ff-only')
}
else {
    Write-DotfilesWarning 'No upstream branch is configured; skipping git pull.'
}

& (Join-Path $RepoRoot 'scripts\install-windows.ps1') -NoRestore
& (Join-Path $RepoRoot 'scripts\restore.ps1')
& (Join-Path $RepoRoot 'scripts\check.ps1')
Write-DotfilesLog 'Sync complete'
