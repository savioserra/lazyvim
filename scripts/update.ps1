[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$RepoRoot = Get-DotfilesRepoRoot
$Tools = Import-ToolManifest (Join-Path $RepoRoot 'manifests\tools.env')
$Nvim = if (-not [string]::IsNullOrWhiteSpace($env:NVIM_BIN)) {
    $env:NVIM_BIN
}
else {
    Join-Path (Get-DotfilesOptHome) "nvim-$($Tools.NEOVIM_VERSION)\bin\nvim.exe"
}
$Chezmoi = if (-not [string]::IsNullOrWhiteSpace($env:CHEZMOI_BIN)) {
    $env:CHEZMOI_BIN
}
else {
    Join-Path (Get-DotfilesOptHome) "chezmoi-$($Tools.CHEZMOI_VERSION)\chezmoi.exe"
}

$changes = & git -C $RepoRoot status --porcelain
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the Git worktree.'
}
if (-not [string]::IsNullOrWhiteSpace(($changes -join "`n"))) {
    throw 'Commit or stash repository changes before updating.'
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
    throw 'Capture or apply managed configuration changes before updating.'
}

Write-DotfilesLog 'Updating plugins and lazy-lock.json'
Invoke-NativeCommand -FilePath $Nvim -Arguments @('--headless', '+Lazy! sync', '+qa')

$lock = Get-Content -LiteralPath (Join-Path $RepoRoot 'home\dot_config\nvim\mason-lock.json') -Raw | ConvertFrom-Json
$packages = @($lock.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
if ($packages.Count -gt 0) {
    Write-DotfilesLog "Updating $($packages.Count) Mason packages"
    Invoke-NativeCommand -FilePath $Nvim -Arguments @(
        '--headless',
        '+Lazy load mason.nvim',
        "+MasonInstall --force --strict $($packages -join ' ')",
        '+qa'
    )
    & (Join-Path $RepoRoot 'scripts\lock-mason.ps1')
}

Write-DotfilesLog 'Updating installed Tree-sitter parsers'
Invoke-NativeCommand -FilePath $Nvim -Arguments @(
    '--headless',
    '+Lazy load nvim-treesitter',
    "+lua assert(require('nvim-treesitter').update(nil, { summary = true }):wait())",
    '+qa'
)

& (Join-Path $RepoRoot 'scripts\capture.ps1') (Join-Path $HOME '.config\nvim')
& (Join-Path $RepoRoot 'scripts\check.ps1')
Write-DotfilesLog 'Update complete; review and commit the lockfile changes.'
