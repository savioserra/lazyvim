[CmdletBinding()]
param()

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

Write-Log 'Checking PowerShell syntax'
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'scripts') -Recurse -File -Filter '*.ps1') {
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -gt 0) {
        throw "PowerShell syntax error in $($file.FullName): $($errors[0].Message)"
    }
}

Write-Log 'Checking JSON files'
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'packages\nvim') -Recurse -File -Filter '*.json') {
    $null = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
}

if (-not (Test-Path -LiteralPath $Nvim -PathType Leaf)) {
    throw 'Pinned Neovim is not installed; run scripts/install.ps1 first.'
}
Write-Log 'Checking pinned Neovim'
$versionOutput = & $Nvim --version
if ($LASTEXITCODE -ne 0) {
    throw 'Neovim failed to report its version.'
}
$actualVersion = ([string]$versionOutput[0]) -replace '^NVIM v', ''
if ($actualVersion -ne $Tools.NEOVIM_VERSION) {
    throw "Expected Neovim $($Tools.NEOVIM_VERSION), found $actualVersion"
}

$configHome = Get-NvimConfigHome
if (-not (Test-PathEntry $configHome) -or
    -not (Get-ResolvedPath $configHome).Equals(
        [System.IO.Path]::GetFullPath((Join-Path $RepoRoot 'packages\nvim')),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    Write-WarningMessage "$configHome is not linked to this repository; run scripts/install.ps1"
}

$dataHome = Get-NvimDataHome
$masonHome = Join-Path $dataHome 'mason'
$stylua = @(
    (Join-Path $masonHome 'bin\stylua.cmd'),
    (Join-Path $masonHome 'bin\stylua.exe')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if ($null -ne $stylua) {
    Write-Log 'Checking Lua formatting'
    Invoke-NativeCommand -FilePath $stylua -Arguments @('--check', (Join-Path $RepoRoot 'packages\nvim\lua'))
}
else {
    Write-WarningMessage 'Stylua is not installed; skipping Lua formatting check.'
}

$packagesHome = Join-Path $masonHome 'packages'
if (Test-Path -LiteralPath $packagesHome -PathType Container) {
    Write-Log 'Checking installed Mason versions'
    $lock = Get-Content -LiteralPath (Join-Path $RepoRoot 'packages\nvim\mason-lock.json') -Raw | ConvertFrom-Json
    foreach ($property in @($lock.PSObject.Properties)) {
        $receipt = Join-Path $packagesHome "$($property.Name)\mason-receipt.json"
        if (-not (Test-Path -LiteralPath $receipt -PathType Leaf)) {
            continue
        }
        $actual = Get-MasonReceiptVersion $receipt
        if ($actual -ne [string]$property.Value) {
            throw "Mason package $($property.Name) is $actual; lockfile requires $($property.Value)"
        }
    }
}

Write-Log 'Checking headless startup'
Invoke-NativeCommand -FilePath $Nvim -Arguments @(
    '--headless',
    "+lua assert(vim.g.lazyvim_ts_lsp == 'vtsls', 'LazyVim options were not loaded')",
    '+qa'
)

Write-Log 'All checks passed'
