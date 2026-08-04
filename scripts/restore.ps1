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
    throw 'Pinned Neovim is not installed; run scripts/install.ps1 first.'
}

$RestorePlugins = -not $MasonOnly
$RestoreMason = -not $PluginsOnly
$RestoreParsers = -not $PluginsOnly -and -not $MasonOnly -and -not $SkipParsers

if ($RestorePlugins) {
    Write-Log 'Restoring plugins from lazy-lock.json'
    Invoke-NativeCommand -FilePath $Nvim -Arguments @('--headless', '+Lazy! restore', '+qa')
}

if ($RestoreMason) {
    $lockPath = Join-Path $RepoRoot 'packages\nvim\mason-lock.json'
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
        Write-Log "Restoring $($specs.Count) Mason package(s) from mason-lock.json"
        Invoke-NativeCommand -FilePath $Nvim -Arguments @(
            '--headless',
            '+Lazy load mason.nvim',
            "+MasonInstall --force --strict $($specs -join ' ')",
            '+qa'
        )
    }
    else {
        Write-Log 'Mason packages already match mason-lock.json'
    }
}

if ($RestoreParsers) {
    Write-Log 'Installing missing Tree-sitter parsers'
    Invoke-NativeCommand -FilePath $Nvim -Arguments @(
        '--headless',
        '+Lazy load nvim-treesitter',
        "+lua require('dotfiles.restore').parsers()",
        '+qa'
    )
}

Write-Log 'Restore complete'
