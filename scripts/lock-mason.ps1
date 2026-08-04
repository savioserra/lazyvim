[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$RepoRoot = Get-DotfilesRepoRoot
$PackagesHome = Join-Path (Get-NvimDataHome) 'mason\packages'
if (-not (Test-Path -LiteralPath $PackagesHome -PathType Container)) {
    throw "Mason package directory does not exist: $PackagesHome"
}

$packages = @{}
foreach ($receipt in Get-ChildItem -LiteralPath $PackagesHome -Recurse -File -Filter 'mason-receipt.json') {
    $data = Get-Content -LiteralPath $receipt.FullName -Raw | ConvertFrom-Json
    $packages[[string]$data.name] = Get-MasonReceiptVersion $receipt.FullName
}

if ($packages.Count -eq 0) {
    throw 'No installed Mason packages found.'
}

$names = [string[]]$packages.Keys
[System.Array]::Sort($names, [System.StringComparer]::Ordinal)
$entries = [ordered]@{}
foreach ($name in $names) {
    $entries[$name] = $packages[$name]
}

$output = Join-Path $RepoRoot 'packages\nvim\mason-lock.json'
$json = $entries | ConvertTo-Json
$encoding = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($output, "$json`n", $encoding)
Write-Log "Locked $($entries.Count) Mason packages in packages\nvim\mason-lock.json"
