[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$RepoRoot = Get-DotfilesRepoRoot
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
