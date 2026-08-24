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

# Chezmoi has now provisioned the tools and configuration. Update this process
# immediately because environment changes made by child scripts only persist
# automatically in future terminals.
$env:XDG_CONFIG_HOME = Join-Path $targetHome '.config'
$managedPaths = @(
  (Join-Path $targetHome '.local\bin'),
  (Join-Path $targetHome '.local\opt\nvim\bin'),
  (Join-Path $targetHome '.local\opt\go\bin'),
  (Join-Path $targetHome '.local\opt\nvm-windows'),
  (Join-Path $targetHome '.local\opt\nvm-windows\nodejs')
)
$env:NVM_HOME = Join-Path $targetHome '.local\opt\nvm-windows'
$env:NVM_SYMLINK = Join-Path $env:NVM_HOME 'nodejs'
$env:PATH = ($managedPaths + $env:PATH) -join [IO.Path]::PathSeparator

$nvimCommand = Get-Command nvim -ErrorAction SilentlyContinue
if ($nvimCommand) {
  $nvim = $nvimCommand.Source
} else {
  $managedNvim = Join-Path $targetHome '.local\opt\nvim\bin\nvim.exe'
  if (-not (Test-Path -LiteralPath $managedNvim -PathType Leaf)) {
    throw 'sync: required command not found: nvim'
  }
  $nvim = $managedNvim
}

function Invoke-NvimOperation {
  param([Parameter(Mandatory)][string]$Operation)

  $lua = "local ok, err = xpcall(function() require('config.sync').run('$Operation') end, debug.traceback); if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end"
  & $nvim --headless -c "lua $lua" +qa
}

Invoke-Step 'Restoring Neovim plugins' {
  Invoke-NvimOperation 'lazy-restore'
}

Invoke-Step 'Removing inactive Neovim plugins' {
  Invoke-NvimOperation 'lazy-clean'
}

Invoke-Step 'Restoring Mason packages' {
  Invoke-NvimOperation 'mason'
}

Invoke-Step 'Updating Tree-sitter parsers' {
  Invoke-NvimOperation 'treesitter'
}

Write-Host "`nSync complete."
