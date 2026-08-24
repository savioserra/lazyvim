param([Parameter(Mandatory)][string]$ScratchHome)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$env:HOME = $ScratchHome
$env:USERPROFILE = $ScratchHome
$env:CHEZMOI_DESTDIR = $ScratchHome
$env:CHEZMOI_SYNC_APPLY_ONLY = '1'
$env:XDG_CONFIG_HOME = Join-Path $ScratchHome '.config'

if ($IsWindows) {
  $env:LOCALAPPDATA = Join-Path $ScratchHome 'AppData/Local'
  & "$repoRoot\sync.ps1"
  $node = Join-Path $ScratchHome '.local\opt\nvm-windows\nodejs\node.exe'
} else {
  $env:XDG_DATA_HOME = Join-Path $ScratchHome '.local/share'
  $env:XDG_STATE_HOME = Join-Path $ScratchHome '.local/state'
  $env:XDG_CACHE_HOME = Join-Path $ScratchHome '.cache'
  & bash "$repoRoot/sync"
  $nodeVersion = (Get-Content (Join-Path $ScratchHome '.node-version') -Raw).Trim()
  $node = Join-Path $ScratchHome ".local/opt/nvm/versions/node/v$nodeVersion/bin/node"
}
if ($LASTEXITCODE -ne 0) { throw "sync failed with exit code $LASTEXITCODE" }

& $node (Join-Path $ScratchHome '.local/share/lazyvim/verify.mjs')
if ($LASTEXITCODE -ne 0) { throw "verification failed with exit code $LASTEXITCODE" }
