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

$node = Join-Path $targetHome '.local\opt\nvm-windows\nodejs\node.exe'
if (-not (Test-Path -LiteralPath $node -PathType Leaf)) {
  throw "sync: managed Node.js not found: $node"
}

Invoke-Step 'Running shared Node.js sync' {
  & $node (Join-Path $targetHome '.local\share\lazyvim\sync.mjs')
}
