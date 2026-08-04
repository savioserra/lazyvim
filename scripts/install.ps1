[CmdletBinding()]
param(
    [switch]$Minimal,
    [switch]$NoFont,
    [switch]$NoRestore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'install-windows.ps1') @PSBoundParameters
