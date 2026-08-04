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

$changes = & git -C $RepoRoot status --porcelain
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the Git worktree.'
}
if (-not [string]::IsNullOrWhiteSpace(($changes -join "`n"))) {
    throw 'Commit or stash repository changes before updating.'
}

Write-Log 'Updating plugins and lazy-lock.json'
Invoke-NativeCommand -FilePath $Nvim -Arguments @('--headless', '+Lazy! sync', '+qa')

$lock = Get-Content -LiteralPath (Join-Path $RepoRoot 'packages\nvim\mason-lock.json') -Raw | ConvertFrom-Json
$packages = @($lock.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
if ($packages.Count -gt 0) {
    Write-Log "Updating $($packages.Count) Mason packages"
    Invoke-NativeCommand -FilePath $Nvim -Arguments @(
        '--headless',
        '+Lazy load mason.nvim',
        "+MasonInstall --force --strict $($packages -join ' ')",
        '+qa'
    )
    & (Join-Path $RepoRoot 'scripts\lock-mason.ps1')
}

Write-Log 'Updating installed Tree-sitter parsers'
Invoke-NativeCommand -FilePath $Nvim -Arguments @(
    '--headless',
    '+Lazy load nvim-treesitter',
    "+lua assert(require('nvim-treesitter').update(nil, { summary = true }):wait())",
    '+qa'
)

& (Join-Path $RepoRoot 'scripts\check.ps1')
Write-Log 'Update complete; review and commit the lockfile changes.'
