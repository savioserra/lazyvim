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

Write-DotfilesLog 'Checking PowerShell syntax'
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

Write-DotfilesLog 'Checking JSON files'
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'home\dot_config\nvim') -Recurse -File -Filter '*.json') {
    $null = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
}

if (-not (Test-Path -LiteralPath $Nvim -PathType Leaf)) {
    throw 'Pinned Neovim is not installed; run scripts/install-windows.ps1 first.'
}
Write-DotfilesLog 'Checking pinned Neovim'
$versionOutput = & $Nvim --version
if ($LASTEXITCODE -ne 0) {
    throw 'Neovim failed to report its version.'
}
$actualVersion = ([string]$versionOutput[0]) -replace '^NVIM v', ''
if ($actualVersion -ne $Tools.NEOVIM_VERSION) {
    throw "Expected Neovim $($Tools.NEOVIM_VERSION), found $actualVersion"
}

$Chezmoi = Join-Path $OptHome "chezmoi-$($Tools.CHEZMOI_VERSION)\chezmoi.exe"
$chezmoiOutput = @(Invoke-NativeCommand -FilePath $Chezmoi -Arguments @('--version'))
if ([string]$chezmoiOutput[0] -notlike "chezmoi version v$($Tools.CHEZMOI_VERSION),*") {
    throw "chezmoi does not match version $($Tools.CHEZMOI_VERSION)"
}

Write-DotfilesLog 'Checking chezmoi source and target state'
$chezmoiDiff = @(Invoke-NativeCommand -FilePath $Chezmoi -Arguments @(
    '--source', $RepoRoot,
    '--destination', $HOME,
    '--no-pager',
    'diff'
))
if (-not [string]::IsNullOrWhiteSpace(($chezmoiDiff -join "`n"))) {
    throw 'Managed configuration differs from the repository; run scripts/capture.ps1 or scripts/apply.ps1.'
}

Write-DotfilesLog 'Checking companion tool versions'
$architecture = Get-WindowsArchitecture
$fdVersion = if ($architecture -eq 'ARM64') {
    $Tools.FD_WINDOWS_ARM64_VERSION
}
else {
    $Tools.FD_WINDOWS_X86_64_VERSION
}

$rgOutput = @(Invoke-NativeCommand `
    -FilePath (Join-Path $OptHome "ripgrep-$($Tools.RIPGREP_VERSION)\rg.exe") `
    -Arguments @('--version'))
if ([string]$rgOutput[0] -notlike "ripgrep $($Tools.RIPGREP_VERSION)*") {
    throw "Ripgrep does not match version $($Tools.RIPGREP_VERSION)"
}

$fdOutput = @(Invoke-NativeCommand `
    -FilePath (Join-Path $OptHome "fd-$fdVersion\fd.exe") `
    -Arguments @('--version'))
if ([string]$fdOutput[0] -ne "fd $fdVersion") {
    throw "fd does not match version $fdVersion"
}

$fzfOutput = @(Invoke-NativeCommand `
    -FilePath (Join-Path $OptHome "fzf-$($Tools.FZF_VERSION)\fzf.exe") `
    -Arguments @('--version'))
if ([string]$fzfOutput[0] -notlike "$($Tools.FZF_VERSION) *") {
    throw "fzf does not match version $($Tools.FZF_VERSION)"
}

$lazygitOutput = @(Invoke-NativeCommand `
    -FilePath (Join-Path $OptHome "lazygit-$($Tools.LAZYGIT_VERSION)\lazygit.exe") `
    -Arguments @('--version'))
if (($lazygitOutput -join "`n") -notmatch "version=$([regex]::Escape($Tools.LAZYGIT_VERSION))(,|$)") {
    throw "lazygit does not match version $($Tools.LAZYGIT_VERSION)"
}

$treeSitterOutput = @(Invoke-NativeCommand `
    -FilePath (Join-Path $OptHome "tree-sitter-$($Tools.TREE_SITTER_VERSION)\tree-sitter.exe") `
    -Arguments @('--version'))
if ([string]$treeSitterOutput[0] -ne "tree-sitter $($Tools.TREE_SITTER_VERSION)") {
    throw "tree-sitter does not match version $($Tools.TREE_SITTER_VERSION)"
}

$configHome = Get-NvimConfigHome
$managedConfigHome = Join-Path $HOME '.config\nvim'
if (-not (Test-PathEntry $configHome) -or
    -not (Get-ResolvedPath $configHome).Equals(
        [System.IO.Path]::GetFullPath($managedConfigHome),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw "$configHome is not linked to the chezmoi-managed Neovim configuration; run scripts/install-windows.ps1"
}

$dataHome = Get-NvimDataHome
$masonHome = Join-Path $dataHome 'mason'
$stylua = @(
    (Join-Path $masonHome 'bin\stylua.cmd'),
    (Join-Path $masonHome 'bin\stylua.exe')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if ($null -ne $stylua) {
    Write-DotfilesLog 'Checking Lua formatting'
    Invoke-NativeCommand -FilePath $stylua -Arguments @('--check', (Join-Path $RepoRoot 'home\dot_config\nvim\lua'))
}
else {
    Write-DotfilesWarning 'Stylua is not installed; skipping Lua formatting check.'
}

$packagesHome = Join-Path $masonHome 'packages'
if (Test-Path -LiteralPath $packagesHome -PathType Container) {
    Write-DotfilesLog 'Checking installed Mason versions'
    $lock = Get-Content -LiteralPath (Join-Path $RepoRoot 'home\dot_config\nvim\mason-lock.json') -Raw | ConvertFrom-Json
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

Write-DotfilesLog 'Checking installed plugin revisions'
Invoke-NativeCommand -FilePath $Nvim -Arguments @(
    '--headless',
    "+lua require('dotfiles.restore').plugins()",
    '+qa'
)

Write-DotfilesLog 'Checking headless startup'
Invoke-NativeCommand -FilePath $Nvim -Arguments @(
    '--headless',
    "+lua assert(vim.g.lazyvim_ts_lsp == 'vtsls', 'LazyVim options were not loaded')",
    '+qa'
)

Write-DotfilesLog 'All checks passed'
