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
  $nvim = Join-Path $ScratchHome '.local\opt\nvim\bin\nvim.exe'
  $stylua = Join-Path $env:LOCALAPPDATA 'nvim-data\mason\bin\stylua.cmd'
} else {
  $env:XDG_DATA_HOME = Join-Path $ScratchHome '.local/share'
  $env:XDG_STATE_HOME = Join-Path $ScratchHome '.local/state'
  $env:XDG_CACHE_HOME = Join-Path $ScratchHome '.cache'
  & bash "$repoRoot/sync"
  $nvim = Join-Path $ScratchHome '.local/opt/nvim/bin/nvim'
  $stylua = Join-Path $env:XDG_DATA_HOME 'nvim/mason/bin/stylua'
}
if ($LASTEXITCODE -ne 0) { throw "sync failed with exit code $LASTEXITCODE" }

& $stylua --check --config-path (Join-Path $repoRoot '.stylua.toml') `
  (Join-Path $repoRoot 'home/dot_local/share/lazyvim') `
  (Join-Path $repoRoot 'home/dot_config/nvim') `
  (Join-Path $repoRoot 'tests')
if ($LASTEXITCODE -ne 0) { throw "Lua formatting check failed with exit code $LASTEXITCODE" }

& $nvim -l (Join-Path $repoRoot 'tests/capabilities.test.lua')
if ($LASTEXITCODE -ne 0) { throw "capability composition tests failed with exit code $LASTEXITCODE" }

& $nvim -l (Join-Path $ScratchHome '.local/share/lazyvim/run.lua') verify
if ($LASTEXITCODE -ne 0) { throw "verification failed with exit code $LASTEXITCODE" }
