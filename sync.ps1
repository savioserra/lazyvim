$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = $PSScriptRoot

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

# Chezmoi deploys the shared Neovim configuration under ~/.config/nvim.
# Native Windows otherwise looks under %LOCALAPPDATA%/nvim. Set this in the
# current process as well as in chezmoi's persistent Windows environment script
# so this sync works immediately after the first apply.
$env:XDG_CONFIG_HOME = Join-Path $HOME '.config'
$managedPaths = @(
  (Join-Path $HOME '.local\bin'),
  (Join-Path $HOME '.local\opt\nvim\bin'),
  (Join-Path $HOME '.local\opt\go\bin'),
  (Join-Path $HOME '.local\opt\nvm-windows'),
  (Join-Path $HOME '.local\opt\nvm-windows\nodejs')
)
$env:NVM_HOME = Join-Path $HOME '.local\opt\nvm-windows'
$env:NVM_SYMLINK = Join-Path $env:NVM_HOME 'nodejs'
$env:PATH = ($managedPaths + $env:PATH) -join [IO.Path]::PathSeparator

# A terminal opened before chezmoi's Windows PATH script ran will not see the
# updated user PATH. Resolve the managed Neovim directly in that case so the
# very first sync works without restarting the terminal.
$nvimCommand = Get-Command nvim -ErrorAction SilentlyContinue
if ($nvimCommand) {
  $nvim = $nvimCommand.Source
} else {
  $managedNvim = Join-Path $HOME '.local\opt\nvim\bin\nvim.exe'
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

Invoke-Step 'Pulling and applying chezmoi source state' {
  & $chezmoi --source $repoRoot update --force
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
