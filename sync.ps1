$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = $PSScriptRoot
$targetHome = if ($env:CHEZMOI_DESTDIR) { $env:CHEZMOI_DESTDIR } else { $HOME }

function Resolve-RequiredCommand {
  param([Parameter(Mandatory)][string]$Name)

  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if (-not $command) {
    throw "sync: required command not found: $Name"
  }
  $command.Source
}

function Invoke-Step {
  param(
    [Parameter(Mandatory)][string]$Description,
    [Parameter(Mandatory)][scriptblock]$Action
  )

  Write-Host "`n==> $Description"
  & $Action
  if ($LASTEXITCODE -ne 0) {
    throw "sync: '$Description' failed with exit code $LASTEXITCODE"
  }
}

$chezmoi = Resolve-RequiredCommand chezmoi

if ($env:CHEZMOI_SYNC_APPLY_ONLY -eq '1') {
  Invoke-Step 'Applying checked-out chezmoi source state' {
    & $chezmoi --source $repoRoot --destination $targetHome apply --force
  }
} else {
  Invoke-Step 'Pulling and applying chezmoi source state' {
    & $chezmoi --source $repoRoot --destination $targetHome update --force
  }
}

$nvim = Join-Path $targetHome '.local\opt\nvim\bin\nvim.exe'
if (-not (Test-Path -LiteralPath $nvim -PathType Leaf)) {
  throw "sync: managed Neovim not found: $nvim"
}

Invoke-Step 'Running Lua capability sync' {
  & $nvim -l (Join-Path $targetHome '.local\share\lazyvim\run.lua') sync
}
