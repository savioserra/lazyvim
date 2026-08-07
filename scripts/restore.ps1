[CmdletBinding()]
param(
    [switch]$PluginsOnly,
    [switch]$MasonOnly,
    [switch]$SkipParsers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$RepoRoot = Get-DotfilesRepoRoot
$Tools = Import-ToolManifest (Join-Path $RepoRoot 'manifests\tools.env')
$OptHome = Get-DotfilesOptHome
$Nvim = if (-not [string]::IsNullOrWhiteSpace($env:NVIM_BIN)) {
    $env:NVIM_BIN
}
else {
    Join-Path $OptHome "nvim-$($Tools.NEOVIM_VERSION)\bin\nvim.exe"
}

if (-not (Test-Path -LiteralPath $Nvim -PathType Leaf)) {
    throw 'Pinned Neovim is not installed; run scripts/install-windows.ps1 first.'
}

& (Join-Path $RepoRoot 'scripts\apply.ps1')

$RestorePlugins = -not $MasonOnly
$RestoreMason = -not $PluginsOnly
$RestoreParsers = -not $PluginsOnly -and -not $MasonOnly -and -not $SkipParsers

if ($RestorePlugins) {
    Write-DotfilesLog 'Installing missing plugins before enforcing lazy-lock.json'
    $committedLock = Join-Path $RepoRoot 'home\dot_config\nvim\lazy-lock.json'
    $activeLock = Join-Path (Join-Path $HOME '.config\nvim') 'lazy-lock.json'
    $lockSnapshot = [System.IO.Path]::GetTempFileName()
    Copy-Item -LiteralPath $committedLock -Destination $lockSnapshot -Force
    try {
        # lazy.nvim only restores plugins that already exist. Install first, then put
        # the committed lockfile back before checking out every exact revision.
        Invoke-NativeCommand -FilePath $Nvim -Arguments @('--headless', '+Lazy! install', '+qa')
        Copy-Item -LiteralPath $lockSnapshot -Destination $activeLock -Force
        Write-DotfilesLog 'Restoring plugins from lazy-lock.json'
        Invoke-NativeCommand -FilePath $Nvim -Arguments @('--headless', '+Lazy! restore', '+qa')
        Copy-Item -LiteralPath $lockSnapshot -Destination $activeLock -Force
        Invoke-NativeCommand -FilePath $Nvim -Arguments @(
            '--headless',
            "+lua require('dotfiles.restore').plugins()",
            '+qa'
        )
    }
    finally {
        Copy-Item -LiteralPath $lockSnapshot -Destination $activeLock -Force
        Remove-Item -LiteralPath $lockSnapshot -Force
    }
}

if ($RestoreMason) {
    $lockPath = Join-Path $RepoRoot 'home\dot_config\nvim\mason-lock.json'
    $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    $packagesHome = Join-Path (Get-NvimDataHome) 'mason\packages'
    $specs = @()

    foreach ($property in @($lock.PSObject.Properties | Sort-Object Name)) {
        $package = $property.Name
        $expected = [string]$property.Value
        $receipt = Join-Path $packagesHome "$package\mason-receipt.json"
        $actual = ''
        if (Test-Path -LiteralPath $receipt -PathType Leaf) {
            $actual = Get-MasonReceiptVersion $receipt
        }
        if ($actual -ne $expected) {
            $specs += "$package@$expected"
        }
    }

    if ($specs.Count -gt 0) {
        Write-DotfilesLog "Restoring $($specs.Count) Mason package(s) from mason-lock.json"
        Invoke-NativeCommand -FilePath $Nvim -Arguments @(
            '--headless',
            '+Lazy load mason.nvim',
            "+MasonInstall --force --strict $($specs -join ' ')",
            '+qa'
        )
    }
    else {
        Write-DotfilesLog 'Mason packages already match mason-lock.json'
    }
}

if ($RestoreParsers) {
    Write-DotfilesLog 'Installing missing Tree-sitter parsers'
    Invoke-NativeCommand -FilePath $Nvim -Arguments @(
        '--headless',
        '+Lazy load nvim-treesitter',
        "+lua require('dotfiles.restore').parsers()",
        '+qa'
    )
}

Write-DotfilesLog 'Restore complete'
