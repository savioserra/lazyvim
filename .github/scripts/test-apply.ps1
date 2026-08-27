param([Parameter(Mandatory)][string]$ScratchHome)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$env:HOME = $ScratchHome
$env:USERPROFILE = $ScratchHome
$env:CHEZMOI_DESTDIR = $ScratchHome
$env:XDG_CONFIG_HOME = Join-Path $ScratchHome '.config'

$nodeVersion = (Get-Content (Join-Path $repoRoot 'home/dot_node-version') -Raw).Trim()
if ($IsWindows) {
  $env:LOCALAPPDATA = Join-Path $ScratchHome 'AppData/Local'
  $nvim = Join-Path $ScratchHome '.local\opt\nvim\bin\nvim.exe'
  $node = Join-Path $ScratchHome ".local\opt\nvm-windows\v$nodeVersion\node.exe"
  $npm = Join-Path $ScratchHome ".local\opt\nvm-windows\v$nodeVersion\npm.cmd"
  $stylua = Join-Path $env:LOCALAPPDATA 'nvim-data\mason\bin\stylua.cmd'
} else {
  $env:XDG_DATA_HOME = Join-Path $ScratchHome '.local/share'
  $env:XDG_STATE_HOME = Join-Path $ScratchHome '.local/state'
  $env:XDG_CACHE_HOME = Join-Path $ScratchHome '.cache'
  $nvim = Join-Path $ScratchHome '.local/opt/nvim/bin/nvim'
  $node = Join-Path $ScratchHome ".local/opt/nvm/versions/node/v$nodeVersion/bin/node"
  $npm = Join-Path $ScratchHome ".local/opt/nvm/versions/node/v$nodeVersion/bin/npm"
  $stylua = Join-Path $env:XDG_DATA_HOME 'nvim/mason/bin/stylua'
}

& chezmoi --source $repoRoot --destination $ScratchHome apply --force
if ($LASTEXITCODE -ne 0) { throw "chezmoi apply failed with exit code $LASTEXITCODE" }

& $stylua --check --config-path (Join-Path $repoRoot '.stylua.toml') `
  (Join-Path $repoRoot 'home/dot_local/share/workstation') `
  (Join-Path $repoRoot 'home/dot_config/nvim') `
  (Join-Path $repoRoot 'tests')
if ($LASTEXITCODE -ne 0) { throw "Lua formatting check failed with exit code $LASTEXITCODE" }

& $nvim -l (Join-Path $repoRoot 'tests/capabilities.test.lua')
if ($LASTEXITCODE -ne 0) { throw "capability composition tests failed with exit code $LASTEXITCODE" }

& $npm ci --omit=dev --ignore-scripts --no-audit --no-fund --prefix (Join-Path $repoRoot 'home/dot_pi/agent/extensions/tmux-subagents')
if ($LASTEXITCODE -ne 0) { throw "tmux-subagents dependency install failed with exit code $LASTEXITCODE" }
$tmuxSubagentTests = Get-ChildItem (Join-Path $repoRoot 'tests/tmux-subagents') -Recurse -Filter '*.test.ts'
if ($IsWindows) {
  $unixOnly = @('ipc-server.test.ts', 'tmux-integration.test.ts', 'extension.test.ts', 'store.test.ts', 'runtime-attestation.test.ts')
  $tmuxSubagentTests = $tmuxSubagentTests | Where-Object { $unixOnly -notcontains $_.Name }
  if (-not ($tmuxSubagentTests | Where-Object { $_.Name -eq 'config.test.ts' })) { throw 'Windows tests must retain the platform-neutral canonical activation-gate test' }
  if (-not ($tmuxSubagentTests | Where-Object { $_.Name -eq 'runtime-platform.test.ts' })) { throw 'Windows tests must retain platform-neutral runtime rejection tests' }
  if (Test-Path (Join-Path $ScratchHome '.pi/agent/extensions/tmux-subagents')) { throw 'Windows apply must exclude the tmux-subagents extension source' }
  if (Test-Path (Join-Path $ScratchHome '.local/bin/workstation-tmux-subagents')) { throw 'Windows apply must exclude the tmux-subagents launcher' }
}
& $node --test ($tmuxSubagentTests | ForEach-Object { $_.FullName })
if ($LASTEXITCODE -ne 0) { throw "tmux-subagents TypeScript tests failed with exit code $LASTEXITCODE" }

& $nvim -l (Join-Path $ScratchHome '.local/share/workstation/apps/cli/run.lua') verify
if ($LASTEXITCODE -ne 0) { throw "verification failed with exit code $LASTEXITCODE" }
